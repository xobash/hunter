${script:HunterContext} = $null

function New-HunterContext {
    return [pscustomobject]@{
        Paths        = @{}
        Flags        = @{}
        UiState      = @{}
        TaskState    = [ordered]@{
            CompletedTasks = @()
            FailedTasks    = @()
            TaskResults    = @{}
            TaskList       = @()
        }
        PackageState = [ordered]@{
            ParallelInstallTargets = @()
            ParallelInstallJobs    = @()
            ParallelInstallResults = @{}
            PrefetchedExternalAssets = @{}
            PrefetchJobs           = @()
            PostInstallCompletion  = @{}
        }
        Runtime      = [ordered]@{
            RunInfrastructureIssues    = @()
            ProgressUiIssueLogged      = $false
            SkipTaskIds                = @()
            DisableIPv6Requested       = $false
            DisableTeredoRequested     = $false
            TeredoPreferenceResolved   = $false
            TeredoDisableResolvedValue = $false
            DisableHagsRequested       = $false
            HagsPreferenceResolved     = $false
            HagsDisableResolvedValue   = $false
            IsAutomationRun            = $false
            StrictMode                 = $false
            PackagePipelineBlocked     = $false
            PackagePipelineBlockReason = ''
            TaskbarReconcilePending    = $false
            ExplorerRestartPending     = $false
            StartSurfaceRestartPending = $false
        }
        Caches       = [ordered]@{
            AppShortcutSetCache            = @{}
            ExecutableResolverCache        = @{}
            ExecutableResolverNextAttemptAt = @{}
            WindowsBuildContext            = $null
            WindowsEditionContext          = $null
            AppRemovalCatalog              = $null
        }
    }
}

function Get-HunterContext {
    $contextVariable = Get-Variable -Name HunterContext -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $contextVariable -or $null -eq $contextVariable.Value) {
        $script:HunterContext = New-HunterContext
    }

    return $script:HunterContext
}

function Set-HunterContext {
    param([Parameter(Mandatory)][object]$Context)

    $script:HunterContext = $Context
    Sync-HunterScriptStateFromContext -Context $Context
}

function Sync-HunterScriptStateFromContext {
    param([object]$Context = (Get-HunterContext))

    if ($null -eq $Context) {
        return
    }

    if ($null -ne $Context.Paths) {
        if ($Context.Paths.ContainsKey('ProgramDataRoot')) { $script:ProgramDataRoot = [string]$Context.Paths.ProgramDataRoot }
        if ($Context.Paths.ContainsKey('ProgramFilesRoot')) { $script:ProgramFilesRoot = [string]$Context.Paths.ProgramFilesRoot }
        if ($Context.Paths.ContainsKey('WindowsRoot')) { $script:WindowsRoot = [string]$Context.Paths.WindowsRoot }
        if ($Context.Paths.ContainsKey('HunterRoot')) { $script:HunterRoot = [string]$Context.Paths.HunterRoot }
        if ($Context.Paths.ContainsKey('LegacyHunterRoot')) { $script:LegacyHunterRoot = [string]$Context.Paths.LegacyHunterRoot }
        if ($Context.Paths.ContainsKey('DownloadDir')) { $script:DownloadDir = [string]$Context.Paths.DownloadDir }
        if ($Context.Paths.ContainsKey('LogPath')) { $script:LogPath = [string]$Context.Paths.LogPath }
        if ($Context.Paths.ContainsKey('CheckpointPath')) { $script:CheckpointPath = [string]$Context.Paths.CheckpointPath }
        if ($Context.Paths.ContainsKey('ResumeScriptPath')) { $script:ResumeScriptPath = [string]$Context.Paths.ResumeScriptPath }
        if ($Context.Paths.ContainsKey('SecretsRoot')) { $script:SecretsRoot = [string]$Context.Paths.SecretsRoot }
        if ($Context.Paths.ContainsKey('RollbackRoot')) { $script:RollbackRoot = [string]$Context.Paths.RollbackRoot }
        if ($Context.Paths.ContainsKey('RollbackManifestPath')) { $script:RollbackManifestPath = [string]$Context.Paths.RollbackManifestPath }
        if ($Context.Paths.ContainsKey('RollbackScriptPath')) { $script:RollbackScriptPath = [string]$Context.Paths.RollbackScriptPath }
        if ($Context.Paths.ContainsKey('RunConfigurationPath')) { $script:RunConfigurationPath = [string]$Context.Paths.RunConfigurationPath }
    }

    if ($null -ne $Context.Flags) {
        if ($Context.Flags.ContainsKey('IsAutomationRun')) { $script:IsAutomationRun = [bool]$Context.Flags.IsAutomationRun }
        if ($Context.Flags.ContainsKey('StrictMode')) { $script:StrictMode = [bool]$Context.Flags.StrictMode }
        if ($Context.Flags.ContainsKey('DisableIPv6Requested')) { $script:DisableIPv6Requested = [bool]$Context.Flags.DisableIPv6Requested }
        if ($Context.Flags.ContainsKey('DisableTeredoRequested')) { $script:DisableTeredoRequested = [bool]$Context.Flags.DisableTeredoRequested }
        if ($Context.Flags.ContainsKey('DisableHagsRequested')) { $script:DisableHagsRequested = [bool]$Context.Flags.DisableHagsRequested }
        if ($Context.Flags.ContainsKey('PackagePipelineBlocked')) { $script:PackagePipelineBlocked = [bool]$Context.Flags.PackagePipelineBlocked }
        if ($Context.Flags.ContainsKey('PackagePipelineBlockReason')) { $script:PackagePipelineBlockReason = [string]$Context.Flags.PackagePipelineBlockReason }
    }

    if ($null -ne $Context.UiState) {
        if ($Context.UiState.ContainsKey('UiSync')) { $script:UiSync = $Context.UiState.UiSync }
        if ($Context.UiState.ContainsKey('UiRunspace')) { $script:UiRunspace = $Context.UiState.UiRunspace }
        if ($Context.UiState.ContainsKey('UiPipeline')) { $script:UiPipeline = $Context.UiState.UiPipeline }
    }

    $script:CompletedTasks = @($Context.TaskState.CompletedTasks)
    $script:FailedTasks = @($Context.TaskState.FailedTasks)
    $script:TaskResults = @{} + $Context.TaskState.TaskResults
    $script:TaskList = @($Context.TaskState.TaskList)

    $script:ParallelInstallTargets = @($Context.PackageState.ParallelInstallTargets)
    $script:ParallelInstallJobs = @($Context.PackageState.ParallelInstallJobs)
    $script:ParallelInstallResults = @{} + $Context.PackageState.ParallelInstallResults
    $script:PrefetchedExternalAssets = @{} + $Context.PackageState.PrefetchedExternalAssets
    $script:ExternalAssetPrefetchJobs = @($Context.PackageState.PrefetchJobs)
    $script:PostInstallCompletion = @{} + $Context.PackageState.PostInstallCompletion

    $script:RunInfrastructureIssues = @($Context.Runtime.RunInfrastructureIssues)
    $script:ProgressUiIssueLogged = [bool]$Context.Runtime.ProgressUiIssueLogged
    $script:SkipTaskIds = @($Context.Runtime.SkipTaskIds)
    $script:DisableIPv6Requested = [bool]$Context.Runtime.DisableIPv6Requested
    $script:DisableTeredoRequested = [bool]$Context.Runtime.DisableTeredoRequested
    $script:TeredoPreferenceResolved = [bool]$Context.Runtime.TeredoPreferenceResolved
    $script:TeredoDisableResolvedValue = [bool]$Context.Runtime.TeredoDisableResolvedValue
    $script:DisableHagsRequested = [bool]$Context.Runtime.DisableHagsRequested
    $script:HagsPreferenceResolved = [bool]$Context.Runtime.HagsPreferenceResolved
    $script:HagsDisableResolvedValue = [bool]$Context.Runtime.HagsDisableResolvedValue
    $script:IsAutomationRun = [bool]$Context.Runtime.IsAutomationRun
    $script:StrictMode = [bool]$Context.Runtime.StrictMode
    $script:PackagePipelineBlocked = [bool]$Context.Runtime.PackagePipelineBlocked
    $script:PackagePipelineBlockReason = [string]$Context.Runtime.PackagePipelineBlockReason
    $script:TaskbarReconcilePending = [bool]$Context.Runtime.TaskbarReconcilePending
    $script:ExplorerRestartPending = [bool]$Context.Runtime.ExplorerRestartPending
    $script:StartSurfaceRestartPending = [bool]$Context.Runtime.StartSurfaceRestartPending

    $script:AppShortcutSetCache = @{} + $Context.Caches.AppShortcutSetCache
    $script:ExecutableResolverCache = @{} + $Context.Caches.ExecutableResolverCache
    $script:ExecutableResolverNextAttemptAt = @{} + $Context.Caches.ExecutableResolverNextAttemptAt
    $script:WindowsBuildContext = $Context.Caches.WindowsBuildContext
    $script:WindowsEditionContext = $Context.Caches.WindowsEditionContext
    $script:AppRemovalCatalog = $Context.Caches.AppRemovalCatalog
}

function Sync-HunterContextFromScriptState {
    param([object]$Context = (Get-HunterContext))

    if ($null -eq $Context) {
        return
    }

    $Context.Paths = @{
        ProgramDataRoot  = $script:ProgramDataRoot
        ProgramFilesRoot = $script:ProgramFilesRoot
        WindowsRoot      = $script:WindowsRoot
        HunterRoot       = $script:HunterRoot
        LegacyHunterRoot = $script:LegacyHunterRoot
        DownloadDir      = $script:DownloadDir
        LogPath          = $script:LogPath
        CheckpointPath   = $script:CheckpointPath
        ResumeScriptPath = $script:ResumeScriptPath
        SecretsRoot      = $script:SecretsRoot
        RollbackRoot     = $script:RollbackRoot
        RollbackManifestPath = $script:RollbackManifestPath
        RollbackScriptPath = $script:RollbackScriptPath
        RunConfigurationPath = $script:RunConfigurationPath
    }

    $Context.Flags = @{
        IsAutomationRun            = $script:IsAutomationRun
        StrictMode                 = $script:StrictMode
        DisableIPv6Requested       = $script:DisableIPv6Requested
        DisableTeredoRequested     = $script:DisableTeredoRequested
        DisableHagsRequested       = $script:DisableHagsRequested
        PackagePipelineBlocked     = $script:PackagePipelineBlocked
        PackagePipelineBlockReason = $script:PackagePipelineBlockReason
    }

    $Context.UiState = @{
        UiSync     = $script:UiSync
        UiRunspace = $script:UiRunspace
        UiPipeline = $script:UiPipeline
    }

    $Context.TaskState.CompletedTasks = @($script:CompletedTasks)
    $Context.TaskState.FailedTasks = @($script:FailedTasks)
    $Context.TaskState.TaskResults = @{} + $script:TaskResults
    $Context.TaskState.TaskList = @($script:TaskList)

    $Context.PackageState.ParallelInstallTargets = @($script:ParallelInstallTargets)
    $Context.PackageState.ParallelInstallJobs = @($script:ParallelInstallJobs)
    $Context.PackageState.ParallelInstallResults = @{} + $script:ParallelInstallResults
    $Context.PackageState.PrefetchedExternalAssets = @{} + $script:PrefetchedExternalAssets
    $Context.PackageState.PrefetchJobs = @($script:ExternalAssetPrefetchJobs)
    $Context.PackageState.PostInstallCompletion = @{} + $script:PostInstallCompletion

    $Context.Runtime.RunInfrastructureIssues = @($script:RunInfrastructureIssues)
    $Context.Runtime.ProgressUiIssueLogged = [bool]$script:ProgressUiIssueLogged
    $Context.Runtime.SkipTaskIds = @($script:SkipTaskIds)
    $Context.Runtime.DisableIPv6Requested = [bool]$script:DisableIPv6Requested
    $Context.Runtime.DisableTeredoRequested = [bool]$script:DisableTeredoRequested
    $Context.Runtime.TeredoPreferenceResolved = [bool]$script:TeredoPreferenceResolved
    $Context.Runtime.TeredoDisableResolvedValue = [bool]$script:TeredoDisableResolvedValue
    $Context.Runtime.DisableHagsRequested = [bool]$script:DisableHagsRequested
    $Context.Runtime.HagsPreferenceResolved = [bool]$script:HagsPreferenceResolved
    $Context.Runtime.HagsDisableResolvedValue = [bool]$script:HagsDisableResolvedValue
    $Context.Runtime.IsAutomationRun = [bool]$script:IsAutomationRun
    $Context.Runtime.StrictMode = [bool]$script:StrictMode
    $Context.Runtime.PackagePipelineBlocked = [bool]$script:PackagePipelineBlocked
    $Context.Runtime.PackagePipelineBlockReason = [string]$script:PackagePipelineBlockReason
    $Context.Runtime.TaskbarReconcilePending = [bool]$script:TaskbarReconcilePending
    $Context.Runtime.ExplorerRestartPending = [bool]$script:ExplorerRestartPending
    $Context.Runtime.StartSurfaceRestartPending = [bool]$script:StartSurfaceRestartPending

    $Context.Caches.AppShortcutSetCache = @{} + $script:AppShortcutSetCache
    $Context.Caches.ExecutableResolverCache = @{} + $script:ExecutableResolverCache
    $Context.Caches.ExecutableResolverNextAttemptAt = @{} + $script:ExecutableResolverNextAttemptAt
    $Context.Caches.WindowsBuildContext = $script:WindowsBuildContext
    $Context.Caches.WindowsEditionContext = $script:WindowsEditionContext
    $Context.Caches.AppRemovalCatalog = $script:AppRemovalCatalog
}
