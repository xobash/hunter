#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {

# Suppress Invoke-WebRequest progress bars BEFORE any downloads occur.
# PowerShell 5.1 renders a UI progress bar that blocks the pipeline and slows
# downloads up to 10x. Must be set at script scope before the bootstrap phase.
# Ref: https://github.com/PowerShell/PowerShell/issues/2138
$ProgressPreference = 'SilentlyContinue'

# Force TLS 1.2+ for all .NET HTTP requests. Windows 10 ships with .NET 4.x
# which defaults to TLS 1.0/1.1 - rejected by most CDNs and GitHub.
# Ref: https://learn.microsoft.com/en-us/dotnet/framework/network-programming/tls
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ==============================================================================
# SCRIPT HEADER + CONFIG
# ==============================================================================

$script:HunterSourceRoot = $null
$script:HunterReleaseChannel = 'main'
$script:HunterReleaseVersion = '2.0.3-main'
$script:HunterBootstrapRevision = 'main'
$script:HunterRemoteRoot = 'https://raw.githubusercontent.com/xobash/hunter/{0}' -f $script:HunterBootstrapRevision
$script:BootstrapLoaderRelativePath = 'src\Hunter\Private\Bootstrap\Loader.ps1'
$script:BootstrapLoaderSha256 = 'bb4d5ef57c38c5059786e2176dc93458e8dfe8c19f4776ebd1f77a58f6cbc90e'

$bootstrapLoaderPath = $null
$canUseLocalHunterPrivateLayers = $false
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $candidateLoaderPath = Join-Path $PSScriptRoot $script:BootstrapLoaderRelativePath
    if (Test-Path $candidateLoaderPath) {
        $script:HunterSourceRoot = $PSScriptRoot
        $bootstrapLoaderPath = $candidateLoaderPath
        $canUseLocalHunterPrivateLayers = $true
    }
}

if ([string]::IsNullOrWhiteSpace($bootstrapLoaderPath)) {
    $script:HunterSourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'HunterBootstrap'
    $bootstrapLoaderPath = Join-Path $script:HunterSourceRoot $script:BootstrapLoaderRelativePath
    $bootstrapLoaderUri = '{0}/{1}' -f $script:HunterRemoteRoot.TrimEnd('/'), ($script:BootstrapLoaderRelativePath -replace '\\', '/')
    $bootstrapLoaderDirectory = Split-Path -Parent $bootstrapLoaderPath
    if (-not (Test-Path $bootstrapLoaderDirectory)) {
        New-Item -ItemType Directory -Path $bootstrapLoaderDirectory -Force | Out-Null
    }

    $bootstrapLoaderResponse = Invoke-WebRequest `
        -Uri $bootstrapLoaderUri `
        -UseBasicParsing `
        -MaximumRedirection 10 `
        -TimeoutSec 120 `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Hunter/2.0' } `
        -ErrorAction Stop
    $bootstrapLoaderContent = $bootstrapLoaderResponse.Content
    if ($bootstrapLoaderContent -is [byte[]]) {
        [System.IO.File]::WriteAllBytes($bootstrapLoaderPath, $bootstrapLoaderContent)
    } else {
        $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($bootstrapLoaderPath, [string]$bootstrapLoaderContent, $utf8NoBomEncoding)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:BootstrapLoaderSha256)) {
        $bootstrapLoaderActualHash = (Get-FileHash -Path $bootstrapLoaderPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($bootstrapLoaderActualHash -ne $script:BootstrapLoaderSha256.ToLowerInvariant()) {
            throw "Integrity check failed for $($script:BootstrapLoaderRelativePath). Expected $($script:BootstrapLoaderSha256), got $bootstrapLoaderActualHash"
        }
    }
}

. ([scriptblock]::Create((Get-Content -Path $bootstrapLoaderPath -Raw -Encoding UTF8)))
Initialize-HunterPrivateSourceTree `
    -SourceRoot $script:HunterSourceRoot `
    -RemoteRoot $(if ($canUseLocalHunterPrivateLayers) { '' } else { $script:HunterRemoteRoot })
foreach ($privateScript in @(Get-HunterPrivateScriptManifest)) {
    $privateScriptPath = Join-Path $script:HunterSourceRoot ([string]$privateScript.RelativePath)
    . ([scriptblock]::Create((Get-Content -Path $privateScriptPath -Raw -Encoding UTF8)))
}

Remove-Variable -Name bootstrapLoaderPath -ErrorAction SilentlyContinue
Remove-Variable -Name bootstrapLoaderUri -ErrorAction SilentlyContinue
Remove-Variable -Name bootstrapLoaderDirectory -ErrorAction SilentlyContinue
Remove-Variable -Name bootstrapLoaderContent -ErrorAction SilentlyContinue
Remove-Variable -Name bootstrapLoaderResponse -ErrorAction SilentlyContinue
Remove-Variable -Name bootstrapLoaderActualHash -ErrorAction SilentlyContinue
Remove-Variable -Name candidateLoaderPath -ErrorAction SilentlyContinue
Remove-Variable -Name canUseLocalHunterPrivateLayers -ErrorAction SilentlyContinue

try {
    if ($null -ne $MyInvocation.MyCommand.ScriptBlock -and $null -ne $MyInvocation.MyCommand.ScriptBlock.Ast) {
        $script:SelfScriptContent = $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text
    }
} catch {
    $script:SelfScriptContent = $null
}

function Write-HunterExecutionPlan {
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [object]$Context = $null
    )

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

    $requestedSkipTaskIds = @($script:SkipTaskIds | Select-Object -Unique)
    $pendingTasks = @(
        $Tasks | Where-Object {
            $taskId = [string]$_.TaskId
            -not (Test-TaskCompleted -TaskId $taskId -Context $Context) -and $taskId -notin $requestedSkipTaskIds
        }
    )

    $completedFromCheckpointCount = @(
        $Tasks | Where-Object { Test-TaskCompleted -TaskId ([string]$_.TaskId) -Context $Context }
    ).Count

    Write-Log 'PLANNED EXECUTION SUMMARY:' 'INFO'
    Write-Log "  Profile:        $($script:SelectedProfile)" 'INFO'
    Write-Log "  Pending Tasks:  $($pendingTasks.Count)" 'INFO'
    Write-Log "  Checkpointed:   $completedFromCheckpointCount" 'INFO'
    Write-Log "  User Skips:     $($requestedSkipTaskIds.Count)" 'INFO'

    foreach ($riskLevel in @('Aggressive', 'Moderate', 'Safe')) {
        $riskCount = @($pendingTasks | Where-Object { [string]$_.RiskLevel -eq $riskLevel }).Count
        Write-Log ("  {0} Risk:      {1}" -f $riskLevel.PadRight(6), $riskCount) 'INFO'
    }

    if ($pendingTasks.Count -eq 0) {
        Write-Log '  No pending tasks remain after checkpoint and skip filtering.' 'INFO'
        return
    }

    foreach ($phaseGroup in @($pendingTasks | Group-Object Phase | Sort-Object { [int]$_.Name })) {
        Write-Log ("  Phase {0} ({1} task(s))" -f $phaseGroup.Name, $phaseGroup.Count) 'INFO'
        foreach ($task in @($phaseGroup.Group)) {
            Write-Log ("    [{0}] {1} - {2}" -f $task.RiskLevel, $task.TaskId, $task.Description) 'INFO'
        }
    }
}


function Invoke-Main {
    <#
    .SYNOPSIS
        Main entry point for the Hunter debloat orchestrator.

    .DESCRIPTION
        Orchestrates the complete Hunter operation, including:
        1. Initialization and validation
        2. Checkpoint/resume recovery
        3. Task building and execution
        4. Reboot handling
        5. Final reporting and cleanup

    .PARAMETER Mode
        Execution mode: 'Execute' for fresh run, 'Resume' for recovering from reboot

    .PARAMETER Strict
        When set, any mandatory task failure after retries causes the entire run to fail immediately.

    .PARAMETER WhatIf
        Preview mode. Hunter builds the selected task list, logs the full execution plan,
        and exits before it mutates the system.

    .PARAMETER Profile
        Preset task selection. Minimal focuses on debloat/privacy, Balanced keeps
        safer gaming-oriented tweaks, Aggressive runs the full catalog, and VMReset
        enables the aggressive opt-ins while suppressing prompts and GUI-only steps.

    .PARAMETER AutomationSafe
        Suppresses UI-only launches and reboot/sign-out actions so the script can
        complete unattended in automation environments.

    .PARAMETER SkipTask
        Optional task IDs to skip during execution.

    .PARAMETER CustomAppsListPath
        Optional path to a text or JSON apps list that overrides the default
        Phase 6 broad-removal catalog selection.

    .PARAMETER DisableIPv6
        Opt in to Hunter's legacy IPv6-disable task. By default Hunter now
        preserves IPv6 because some remote-access and gaming services rely on it.

    .PARAMETER DisableTeredo
        Opt in to Hunter's Teredo-disable task. By default Hunter now preserves
        Teredo because some gaming and VPN scenarios still rely on it.

    .PARAMETER DisableCpuMitigations
        Opt in to disabling Spectre/Meltdown speculative-execution mitigations
        through FeatureSettingsOverride/FeatureSettingsOverrideMask.

    .PARAMETER DisableHags
        Opt out of Hunter's default HAGS enable policy and apply the legacy
        HAGS disable override instead.

    .PARAMETER ForceStorageOptimization
        Opt in to aggressive storage tweaks that delete the NTFS USN journal
        and disable disk write-cache buffer flushing.

    .PARAMETER DisableAudioEnhancements
        Opt in to disabling Windows audio enhancements.

    .PARAMETER DisableSystemSounds
        Opt in to replacing the Windows sound scheme with Hunter's silent
        profile.

    .PARAMETER ForceTextInputServiceRedirect
        Opt in to the advanced TextInputManagementService ServiceDll redirect.

    .PARAMETER RunTcpOptimizer
        Opt in to downloading and launching the third-party TCP Optimizer
        executable for manual verification after Hunter applies its native
        TCP/network settings.

    .PARAMETER RunOOSU
        Opt in to downloading and executing the third-party O&O ShutUp10
        utility and preset import workflow.

    .PARAMETER PagefileDrive
        Optional fixed-drive letter (for example `D:`) to host `pagefile.sys`
        instead of the system drive.
    #>

    param(
        [ValidateSet('Execute', 'Resume')]
        [string]$Mode = 'Execute',

        [switch]$Strict,

        [switch]$WhatIf,

        [ValidateSet('Minimal', 'Balanced', 'Aggressive', 'VMReset')]
        [string]$Profile = 'Aggressive',

        [switch]$AutomationSafe,

        [string[]]$SkipTask = @(),

        [string]$CustomAppsListPath = '',

        [switch]$DisableIPv6,

        [switch]$DisableTeredo,

        [switch]$DisableCpuMitigations,

        [switch]$DisableHags,

        [switch]$ForceStorageOptimization,

        [switch]$DisableAudioEnhancements,

        [switch]$DisableSystemSounds,

        [switch]$ForceTextInputServiceRedirect,

        [switch]$RunTcpOptimizer,

        [switch]$RunOOSU,

        [string]$PagefileDrive = ''
    )

    $script:StrictMode = [bool]$Strict
    $script:DryRunMode = [bool]$WhatIf -or $env:HUNTER_WHATIF -eq '1'
    $script:SelectedProfile = if ([string]::IsNullOrWhiteSpace($Profile)) { 'Aggressive' } else { [string]$Profile }
    $script:SkipTaskIds = @(
        $SkipTask |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Split(',') } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $script:CustomAppsListPathOverride = if ([string]::IsNullOrWhiteSpace($CustomAppsListPath)) { $null } else { $CustomAppsListPath }
    $script:DisableIPv6Requested = [bool]$DisableIPv6 -or $env:HUNTER_DISABLE_IPV6 -eq '1'
    $script:DisableTeredoRequested = [bool]$DisableTeredo -or $env:HUNTER_DISABLE_TEREDO -eq '1'
    $script:TeredoPreferenceResolved = $false
    $script:TeredoDisableResolvedValue = $false
    $script:DisableCpuMitigationsRequested = [bool]$DisableCpuMitigations -or $env:HUNTER_DISABLE_CPU_MITIGATIONS -eq '1'
    $script:DisableHagsRequested = [bool]$DisableHags -or $env:HUNTER_DISABLE_HAGS -eq '1'
    $script:HagsPreferenceResolved = $false
    $script:HagsDisableResolvedValue = $false
    $script:ForceStorageOptimizationRequested = [bool]$ForceStorageOptimization -or $env:HUNTER_FORCE_STORAGE_OPTIMIZATION -eq '1'
    $script:DisableAudioEnhancementsRequested = [bool]$DisableAudioEnhancements -or $env:HUNTER_DISABLE_AUDIO_ENHANCEMENTS -eq '1'
    $script:DisableSystemSoundsRequested = [bool]$DisableSystemSounds -or $env:HUNTER_DISABLE_SYSTEM_SOUNDS -eq '1'
    $script:ForceTextInputServiceRedirectRequested = [bool]$ForceTextInputServiceRedirect -or $env:HUNTER_FORCE_TEXT_INPUT_SERVICE_REDIRECT -eq '1'
    $script:RunTcpOptimizerRequested = [bool]$RunTcpOptimizer -or $env:HUNTER_RUN_TCP_OPTIMIZER -eq '1'
    $script:RunOOSURequested = [bool]$RunOOSU -or $env:HUNTER_RUN_OOSU -eq '1'
    $script:PagefileDriveOverride = if ([string]::IsNullOrWhiteSpace($PagefileDrive)) { $null } else { $PagefileDrive.Trim() }
    $script:RunInfrastructureIssues = @()
    $script:ProgressUiIssueLogged = $false
    $script:PackagePipelineBlocked = $false
    $script:PackagePipelineBlockReason = ''
    $profileIsVmReset = $script:SelectedProfile -eq 'VMReset'
    if ($profileIsVmReset) {
        $AutomationSafe = $true
        $script:DisableIPv6Requested = $true
        $script:DisableTeredoRequested = $true
        $script:DisableCpuMitigationsRequested = $true
        $script:ForceStorageOptimizationRequested = $true
        $script:DisableAudioEnhancementsRequested = $true
        $script:DisableSystemSoundsRequested = $true
        $script:ForceTextInputServiceRedirectRequested = $true
    }
    $script:IsAutomationRun = [bool]$AutomationSafe -or $env:GITHUB_ACTIONS -eq 'true' -or $env:HUNTER_AUTOMATION_SAFE -eq '1'
    $context = Get-HunterContext
    Sync-HunterContextFromScriptState -Context $context

    # Start the run stopwatch immediately - this is the very first executable line
    $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # --------------------------------------------------------------------
        # INITIALIZATION
        # --------------------------------------------------------------------

        # $ProgressPreference is set at script scope before bootstrap (line 8).

        # Ensure directories exist
        Initialize-HunterDirectory $script:HunterRoot
        Initialize-HunterDirectory $script:DownloadDir
        Migrate-HunterStateToProgramData
        $buildContext = Get-WindowsBuildContext
        $editionContext = Get-WindowsEditionContext
        $editionSummary = (@(
            [string]$editionContext.ProductName,
            [string]$editionContext.EditionId,
            [string]$editionContext.InstallationType
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' | '

        Write-Log "===========================================================" 'INFO'
        Write-Log '              HUNTER v2.0 - Windows Debloater' 'INFO'
        Write-Log "===========================================================" 'INFO'
        Write-Log ""
        Write-Log "Execution Mode:  $Mode" 'INFO'
        Write-Log "Release Channel: $($script:HunterReleaseChannel)" 'INFO'
        Write-Log "Release Version: $($script:HunterReleaseVersion)" 'INFO'
        Write-Log "OS Version:      $([System.Environment]::OSVersion.VersionString)" 'INFO'
        Write-Log "Windows Build:   $($buildContext.CurrentBuild).$($buildContext.UBR) $(if (-not [string]::IsNullOrWhiteSpace($buildContext.DisplayVersion)) { "($($buildContext.DisplayVersion))" } elseif (-not [string]::IsNullOrWhiteSpace($buildContext.ReleaseId)) { "($($buildContext.ReleaseId))" } else { '' })" 'INFO'
        if (-not [string]::IsNullOrWhiteSpace($buildContext.ProductName)) {
            Write-Log "Windows SKU:     $($buildContext.ProductName)" 'INFO'
        }
        if (-not [string]::IsNullOrWhiteSpace($editionSummary)) {
            Write-Log "Edition:         $editionSummary" 'INFO'
        }
        Write-Log "User:            $env:USERNAME on $env:COMPUTERNAME" 'INFO'
        Write-Log "Timestamp:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 'INFO'
        Write-Log "Automation:      $(if ($script:IsAutomationRun) { 'YES' } else { 'NO' })" 'INFO'
        Write-Log "Profile:         $($script:SelectedProfile)" 'INFO'
        Write-Log "Preview Only:    $(if ($script:DryRunMode) { 'YES' } else { 'NO' })" 'INFO'
        Write-Log ""

        # Log administrator status (#Requires -RunAsAdministrator already enforces elevation)
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Log "Administrator:   $(if ($isAdmin) { 'YES' } else { 'NO' })" 'INFO'
        Write-Log "Activation:      $(Get-WindowsActivationStateSummary)" 'INFO'

        Write-Log ""

        # Check Windows version
        $osVersion = [System.Environment]::OSVersion.Version
        if ($osVersion.Major -lt 10) {
            Write-Log "ERROR: Hunter requires Windows 10 or later" 'ERROR'
            exit 1
        }

        # --------------------------------------------------------------------
        # DETECTION & RECOVERY
        # --------------------------------------------------------------------

        # Detect Hyper-V guest status
        Initialize-HyperVDetection
        Write-Log "Hyper-V Guest:   $(if ($script:IsHyperVGuest) { 'YES' } else { 'NO' })" 'INFO'

        Write-Log ""

        # Load checkpoint (recovery from previous run/reboot)
        Load-Checkpoint -Context $context

        # --------------------------------------------------------------------
        # BUILD & PREPARE TASKS
        # --------------------------------------------------------------------

        Write-Log "Building task list..." 'INFO'
        $tasks = Build-Tasks -Context $context
        $script:TaskList = @($tasks)
        Sync-HunterContextFromScriptState -Context $context
        Write-Log "Task list built: $($tasks.Count) total tasks" 'SUCCESS'
        if (@($script:SkipTaskIds).Count -gt 0) {
            Write-Log "User-requested task skips: $($script:SkipTaskIds -join ', ')" 'INFO'

            $knownTaskIds = @($tasks | ForEach-Object { [string]$_.TaskId })
            $unknownSkipTaskIds = @($script:SkipTaskIds | Where-Object { $_ -notin $knownTaskIds })
            if ($unknownSkipTaskIds.Count -gt 0) {
                Write-Log "Unknown task IDs requested for skip: $($unknownSkipTaskIds -join ', ')" 'WARN'
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CustomAppsListPathOverride)) {
            Write-Log "Custom apps list: $($script:CustomAppsListPathOverride)" 'INFO'
        }
        if ($profileIsVmReset) {
            Write-Log 'VMReset profile selected. Hunter is suppressing prompts and GUI-only launches, skipping restore-point creation, and enabling the aggressive opt-in tweak set.' 'WARN'
        }
        if ($script:DisableCpuMitigationsRequested) {
            Write-Log 'Speculative-execution mitigation override requested explicitly.' 'WARN'
        }
        if ($script:ForceStorageOptimizationRequested) {
            Write-Log 'Aggressive storage tweaks were requested explicitly.' 'WARN'
        }
        if ($script:DisableAudioEnhancementsRequested) {
            Write-Log 'Audio-enhancement disable was requested explicitly.' 'WARN'
        }
        if ($script:DisableSystemSoundsRequested) {
            Write-Log 'System sound-scheme disable was requested explicitly.' 'WARN'
        }
        if ($script:ForceTextInputServiceRedirectRequested) {
            Write-Log 'Advanced text-input service redirect was requested explicitly.' 'WARN'
        }
        if ($script:RunTcpOptimizerRequested) {
            Write-Log 'Third-party TCP Optimizer execution was requested explicitly.' 'WARN'
        }
        if ($script:RunOOSURequested) {
            Write-Log 'Third-party O&O ShutUp10 execution was requested explicitly.' 'WARN'
        }
        if (-not [string]::IsNullOrWhiteSpace($script:PagefileDriveOverride)) {
            Write-Log "Pagefile target override: $($script:PagefileDriveOverride)" 'INFO'
        }
        Write-HunterExecutionPlan -Tasks $tasks -Context $context

        Write-Log ""

        if ($script:DryRunMode) {
            Write-Log 'Dry-run preview complete. Re-run without -WhatIf to execute the selected profile.' 'INFO'
            return $true
        }

        Initialize-HunterInteractivePreferences -Tasks $tasks -Context $context
        Sync-HunterContextFromScriptState -Context $context

        Initialize-HunterRollbackState -Mode $Mode
        Save-HunterRunConfiguration -Mode $Mode -SkipTaskIds $script:SkipTaskIds -CustomAppsListPath $(Get-HunterEffectiveCustomAppsListPath) -PagefileDrive ([string]$script:PagefileDriveOverride)

        # Initialize tracking arrays
        if (-not $script:TaskResults) {
            $script:TaskResults = @{}
        }

        # --------------------------------------------------------------------
        # PROGRESS & SCHEDULING
        # --------------------------------------------------------------------

        Write-Log "Initializing progress tracking..." 'INFO'
        Update-ProgressState -Tasks $tasks
        Start-ProgressWindow
        Sync-HunterContextFromScriptState -Context $context

        Write-Log "Registering resume recovery task..." 'INFO'
        Register-ResumeTask

        Write-Log ""
        Write-Log '==== EXECUTION BEGINNING ====' 'INFO'
        Write-Log ""

        # --------------------------------------------------------------------
        # EXECUTE ALL TASKS
        # --------------------------------------------------------------------

        Invoke-TaskExecution -Tasks $tasks -SkipTask $script:SkipTaskIds -Context $context

        Write-Log ""
        Write-Log '==== EXECUTION COMPLETE ====' 'INFO'
        Write-Log ""

        # --------------------------------------------------------------------
        # CLEANUP & FINALIZATION
        # --------------------------------------------------------------------

        # Unregister resume task (success path)
        Unregister-ResumeTask | Out-Null

        # Stop the run stopwatch
        if ($null -ne $script:RunStopwatch) { $script:RunStopwatch.Stop() }
        $elapsedTime = if ($null -ne $script:RunStopwatch) { Format-ElapsedDuration $script:RunStopwatch.Elapsed } else { 'N/A' }

        # Calculate statistics
        $completedCount = @($tasks | Where-Object { $_.Status -eq 'Completed' }).Count
        $warningCount = @($tasks | Where-Object { $_.Status -eq 'CompletedWithWarnings' }).Count
        $skippedCount = @($tasks | Where-Object { $_.Status -eq 'Skipped' }).Count
        $failedCount = @($tasks | Where-Object { $_.Status -eq 'Failed' }).Count
        $totalCount = $tasks.Count
        $successRate = if ($totalCount -gt 0) { [math]::Round(($completedCount / $totalCount) * 100, 1) } else { 0 }
        $infrastructureIssueCount = @($script:RunInfrastructureIssues).Count
        $runHadIssues = ($failedCount -gt 0) -or ($infrastructureIssueCount -gt 0)

        Write-Log "FINAL SUMMARY:" 'INFO'
        Write-Log "  Elapsed Time:   $elapsedTime" 'INFO'
        Write-Log "  Total Tasks:    $totalCount" 'INFO'
        Write-Log "  Completed:      $completedCount" 'INFO'
        Write-Log "  Warnings:       $warningCount" 'INFO'
        Write-Log "  Skipped:        $skippedCount" 'INFO'
        Write-Log "  Failed:         $failedCount" 'INFO'
        Write-Log "  Infra Issues:   $infrastructureIssueCount" 'INFO'
        Write-Log "  Success Rate:   $successRate%" 'INFO'

        if ($infrastructureIssueCount -gt 0) {
            foreach ($issue in @($script:RunInfrastructureIssues)) {
                Write-Log "  Infra Detail:   $issue" 'WARN'
            }
        }

        Write-Log ""
        Sync-HunterContextFromScriptState -Context $context
        Save-Checkpoint -Context $context
        Close-ProgressWindow

        # Check for pending reboot
        $pendingReboot = Test-PendingReboot
        if ($null -eq $pendingReboot) {
            Write-Log "Pending reboot state could not be determined." 'WARN'
        } elseif ($pendingReboot) {
            if ($runHadIssues) {
                Write-Log "Pending reboot was detected, but Hunter completed with issues. Automatic reboot is being skipped so you can review the report first." 'WARN'
            } elseif ($script:IsAutomationRun) {
                Write-Log "Pending reboot detected, but automation-safe mode is active; skipping reboot." 'WARN'
            } else {
                $rebootNotice = 'Hunter completed and will reboot this PC in 30 seconds. Run shutdown /a to cancel.'
                Write-Log $rebootNotice 'WARN'
                Write-Log ""
                Start-Process -FilePath shutdown.exe -ArgumentList @('/r', '/t', '30', '/c', $rebootNotice) -WindowStyle Hidden
                return
            }
        } else {
            Write-Log "No pending reboot required" 'SUCCESS'
        }

        Write-Log ""
        Write-Log "===========================================================" 'INFO'
        Write-Log ("                    HUNTER {0}" -f $(if ($runHadIssues) { 'COMPLETED WITH ISSUES' } else { 'COMPLETED' })) 'INFO'
        Write-Log "===========================================================" 'INFO'
        Write-Log "" 'INFO'
        if ($runHadIssues) {
            Write-Log 'Autonomous run completed, but one or more tasks or run-infrastructure checks reported issues. Review the summary and report before trusting the system state.' 'WARN'
            return $false
        }

        Write-Log 'Autonomous run complete. Exiting without waiting for user input.' 'INFO'
        return $true

    } catch {
        Write-Log ""
        $errMsg = $_.ToString()
        $stackMsg = $_.ScriptStackTrace
        Write-Log "CRITICAL ERROR: $errMsg" 'ERROR'
        Write-Log "Stack trace: $stackMsg" 'ERROR'
        Write-Log ""
        exit 1
    }
}

#=============================================================================
# ENTRY POINT
#=============================================================================

# Determine execution parameters from command-line arguments
$scriptMode = 'Execute'
$scriptStrict = $false
$scriptWhatIf = $false
$scriptProfile = 'Aggressive'
$scriptLogPath = $null
$scriptAutomationSafe = $false
$scriptSkipTasks = @()
$scriptCustomAppsListPath = $null
$scriptDisableIPv6 = $false
$scriptDisableTeredo = $false
$scriptDisableCpuMitigations = $false
$scriptDisableHags = $false
$scriptForceStorageOptimization = $false
$scriptDisableAudioEnhancements = $false
$scriptDisableSystemSounds = $false
$scriptForceTextInputServiceRedirect = $false
$scriptRunTcpOptimizer = $false
$scriptRunOOSU = $false
$scriptPagefileDrive = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-Mode' -and ($i + 1) -lt $args.Count) {
        $scriptMode = $args[$i + 1]
    }
    elseif ($args[$i] -eq '-Strict') {
        $scriptStrict = $true
    }
    elseif ($args[$i] -eq '-WhatIf') {
        $scriptWhatIf = $true
    }
    elseif ($args[$i] -eq '-Profile' -and ($i + 1) -lt $args.Count) {
        $scriptProfile = $args[$i + 1]
    }
    elseif ($args[$i] -eq '-LogPath' -and ($i + 1) -lt $args.Count) {
        $scriptLogPath = $args[$i + 1]
    }
    elseif ($args[$i] -eq '-AutomationSafe') {
        $scriptAutomationSafe = $true
    }
    elseif ($args[$i] -eq '-SkipTask' -and ($i + 1) -lt $args.Count) {
        $scriptSkipTasks += @(
            [string]$args[$i + 1] -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    elseif ($args[$i] -eq '-CustomAppsListPath' -and ($i + 1) -lt $args.Count) {
        $scriptCustomAppsListPath = $args[$i + 1]
    }
    elseif ($args[$i] -eq '-DisableIPv6') {
        $scriptDisableIPv6 = $true
    }
    elseif ($args[$i] -eq '-DisableTeredo') {
        $scriptDisableTeredo = $true
    }
    elseif ($args[$i] -eq '-DisableCpuMitigations') {
        $scriptDisableCpuMitigations = $true
    }
    elseif ($args[$i] -eq '-DisableHags') {
        $scriptDisableHags = $true
    }
    elseif ($args[$i] -eq '-ForceStorageOptimization') {
        $scriptForceStorageOptimization = $true
    }
    elseif ($args[$i] -eq '-DisableAudioEnhancements') {
        $scriptDisableAudioEnhancements = $true
    }
    elseif ($args[$i] -eq '-DisableSystemSounds') {
        $scriptDisableSystemSounds = $true
    }
    elseif ($args[$i] -eq '-ForceTextInputServiceRedirect') {
        $scriptForceTextInputServiceRedirect = $true
    }
    elseif ($args[$i] -eq '-RunTcpOptimizer') {
        $scriptRunTcpOptimizer = $true
    }
    elseif ($args[$i] -eq '-RunOOSU') {
        $scriptRunOOSU = $true
    }
    elseif ($args[$i] -eq '-PagefileDrive' -and ($i + 1) -lt $args.Count) {
        $scriptPagefileDrive = $args[$i + 1]
    }
}

# Override log path if provided
if (-not [string]::IsNullOrWhiteSpace($scriptLogPath)) {
    $script:LogPath = $scriptLogPath
}

# Invoke main orchestrator
Invoke-Main -Mode $scriptMode -Strict:$scriptStrict -WhatIf:$scriptWhatIf -Profile $scriptProfile -AutomationSafe:$scriptAutomationSafe -SkipTask $scriptSkipTasks -CustomAppsListPath $scriptCustomAppsListPath -DisableIPv6:$scriptDisableIPv6 -DisableTeredo:$scriptDisableTeredo -DisableCpuMitigations:$scriptDisableCpuMitigations -DisableHags:$scriptDisableHags -ForceStorageOptimization:$scriptForceStorageOptimization -DisableAudioEnhancements:$scriptDisableAudioEnhancements -DisableSystemSounds:$scriptDisableSystemSounds -ForceTextInputServiceRedirect:$scriptForceTextInputServiceRedirect -RunTcpOptimizer:$scriptRunTcpOptimizer -RunOOSU:$scriptRunOOSU -PagefileDrive $scriptPagefileDrive
} catch {
    $crashLogPath = Join-Path ([System.IO.Path]::GetTempPath()) 'hunter-crash.txt'
    $crashTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $crashMessage = $_.ToString()
    $crashStack = $_.ScriptStackTrace
    $crashLines = @(
        "[${crashTimestamp}] Hunter crashed before normal completion.",
        "Message: $crashMessage"
    )

    if (-not [string]::IsNullOrWhiteSpace($crashStack)) {
        $crashLines += @(
            'StackTrace:',
            $crashStack
        )
    }

    try {
        $crashLines | Set-Content -Path $crashLogPath -Encoding UTF8 -Force
    } catch {
    }

    try {
        [Console]::Error.WriteLine("[Hunter] Fatal bootstrap error. Crash details were written to $crashLogPath")
        [Console]::Error.WriteLine("[Hunter] $crashMessage")
    } catch {
    }

    exit 1
}
