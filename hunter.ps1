#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {

# Force TLS 1.2+ for all .NET HTTP requests. Windows 10 ships with .NET 4.x
# which defaults to TLS 1.0/1.1 - rejected by most CDNs and GitHub.
# Ref: https://learn.microsoft.com/en-us/dotnet/framework/network-programming/tls
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ==============================================================================
# SCRIPT HEADER + CONFIG
# ==============================================================================

$script:HunterSourceRoot = $null
$script:HunterReleaseChannel = 'preview'
$script:HunterReleaseVersion = '2.0.3-preview.1'
$script:HunterBootstrapRevision = 'aaf08429d58185cf1d34ddcbecc947c1fa7f2e89'
$script:HunterRemoteRevision = $script:HunterBootstrapRevision
$script:HunterRemoteRoot = 'https://raw.githubusercontent.com/xobash/hunter/{0}' -f $script:HunterBootstrapRevision
$script:BootstrapLoaderRelativePath = 'src\Hunter\Private\Bootstrap\Loader.ps1'
$script:BootstrapLoaderSha256 = 'f2fe977177a4298459f29dba6f1b96891f2af084c8dfb550f31e4d8690c08ed4'

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

. $bootstrapLoaderPath
Initialize-HunterPrivateSourceTree `
    -SourceRoot $script:HunterSourceRoot `
    -RemoteRoot $(if ($canUseLocalHunterPrivateLayers) { '' } else { $script:HunterRemoteRoot })
foreach ($privateScript in @(Get-HunterPrivateScriptManifest)) {
    . (Join-Path $script:HunterSourceRoot ([string]$privateScript.RelativePath))
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

    .PARAMETER DisableHags
        Opt out of Hunter's default HAGS enable policy and apply the legacy
        HAGS disable override instead.
    #>

    param(
        [ValidateSet('Execute', 'Resume')]
        [string]$Mode = 'Execute',

        [switch]$Strict,

        [switch]$AutomationSafe,

        [string[]]$SkipTask = @(),

        [string]$CustomAppsListPath = '',

        [switch]$DisableIPv6,

        [switch]$DisableTeredo,

        [switch]$DisableHags
    )

    $script:StrictMode = [bool]$Strict
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
    $script:DisableHagsRequested = [bool]$DisableHags -or $env:HUNTER_DISABLE_HAGS -eq '1'
    $script:HagsPreferenceResolved = $false
    $script:HagsDisableResolvedValue = $false
    $script:RunInfrastructureIssues = @()
    $script:ProgressUiIssueLogged = $false
    $script:PackagePipelineBlocked = $false
    $script:PackagePipelineBlockReason = ''
    $context = Get-HunterContext
    Sync-HunterContextFromScriptState -Context $context

    # Start the run stopwatch immediately - this is the very first executable line
    $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # --------------------------------------------------------------------
        # INITIALIZATION
        # --------------------------------------------------------------------

        # Suppress Invoke-WebRequest progress bars - PS5 renders a UI progress bar
        # that slows downloads up to 10x. Ref: https://github.com/PowerShell/PowerShell/issues/2138
        $ProgressPreference = 'SilentlyContinue'

        # Ensure directories exist
        Initialize-HunterDirectory $script:HunterRoot
        Initialize-HunterDirectory $script:DownloadDir
        Migrate-HunterStateToProgramData
        $script:IsAutomationRun = [bool]$AutomationSafe -or $env:GITHUB_ACTIONS -eq 'true' -or $env:HUNTER_AUTOMATION_SAFE -eq '1'
        Initialize-HunterRollbackState -Mode $Mode
        Save-HunterRunConfiguration -Mode $Mode -SkipTaskIds $script:SkipTaskIds -CustomAppsListPath $(Get-HunterEffectiveCustomAppsListPath)
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

        Write-Log ""

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
$scriptLogPath = $null
$scriptAutomationSafe = $false
$scriptSkipTasks = @()
$scriptCustomAppsListPath = $null
$scriptDisableIPv6 = $false
$scriptDisableTeredo = $false
$scriptDisableHags = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-Mode' -and ($i + 1) -lt $args.Count) {
        $scriptMode = $args[$i + 1]
    }
    elseif ($args[$i] -eq '-Strict') {
        $scriptStrict = $true
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
    elseif ($args[$i] -eq '-DisableHags') {
        $scriptDisableHags = $true
    }
}

# Override log path if provided
if (-not [string]::IsNullOrWhiteSpace($scriptLogPath)) {
    $script:LogPath = $scriptLogPath
}

# Invoke main orchestrator
Invoke-Main -Mode $scriptMode -Strict:$scriptStrict -AutomationSafe:$scriptAutomationSafe -SkipTask $scriptSkipTasks -CustomAppsListPath $scriptCustomAppsListPath -DisableIPv6:$scriptDisableIPv6 -DisableTeredo:$scriptDisableTeredo -DisableHags:$scriptDisableHags
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
