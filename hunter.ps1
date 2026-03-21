#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force TLS 1.2+ for all .NET HTTP requests. Windows 10 ships with .NET 4.x
# which defaults to TLS 1.0/1.1 — rejected by most CDNs and GitHub.
# Ref: https://learn.microsoft.com/en-us/dotnet/framework/network-programming/tls
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ==============================================================================
# SCRIPT HEADER + CONFIG
# ==============================================================================

$script:ProgramDataRoot   = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { 'C:\ProgramData' } else { $env:ProgramData }
$script:ProgramFilesRoot  = if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) { 'C:\Program Files' } else { $env:ProgramFiles }
$script:WindowsRoot       = if ([string]::IsNullOrWhiteSpace($env:WINDIR)) { 'C:\Windows' } else { $env:WINDIR }
$script:HunterRoot        = Join-Path $script:ProgramDataRoot 'Hunter'
$script:DownloadDir        = Join-Path $script:HunterRoot 'Downloads'
$script:LogPath            = Join-Path $script:HunterRoot 'hunter.log'
$script:CheckpointPath     = Join-Path $script:HunterRoot 'checkpoint.json'
$script:ResumeScriptPath   = Join-Path $script:HunterRoot 'Resume\hunter.ps1'
$script:SecretsRoot        = Join-Path $script:HunterRoot 'Secrets'
$script:LocalUserSecretPath = Join-Path $script:SecretsRoot 'local-user.secret'
$script:AllUsersStartMenuProgramsPath = Join-Path $script:ProgramDataRoot 'Microsoft\Windows\Start Menu\Programs'
$script:HostsFilePath      = Join-Path $script:WindowsRoot 'System32\drivers\etc\hosts'
$script:TaskbarPinVerbPatterns = @('*Pin to taskbar*', '*taskbarpin*')
$script:TaskbarUnpinVerbPatterns = @('*Unpin from taskbar*', '*taskbarunpin*')
$script:TaskbarStatePollIntervalMs = 300
$script:TaskbarStateTimeoutSec = 6
$script:StartSurfaceReadyTimeoutSec = 5
$script:GitHubApiMaxAttempts = 3
$script:GitHubApiBaseDelaySec = 2
$script:IsHyperVGuest      = $false
$script:ExplorerRestartPending = $false
$script:StartSurfaceRestartPending = $false
$script:ParallelInstallTargets = @()
$script:ParallelInstallJobs = @()
$script:ParallelInstallResults = @{}
$script:PrefetchedExternalAssets = @{}
$script:ExternalAssetPrefetchJobs = @()
$script:AppShortcutSetCache = @{}
$script:ExecutableResolverCache = @{}
$script:ExecutableResolverNextAttemptAt = @{}
$script:IsAutomationRun = $false
$script:TaskbarReconcilePending = $false
$script:DefaultTaskbarPinsRemoved = $false
$script:EdgeShortcutsRemoved = $false
$script:PostInstallCompletion = @{}
$script:RunStopwatch = $null
$script:RunInfrastructureIssues = @()
$script:CheckpointLoadFailed = $false
$script:CheckpointSaveFailed = $false
$script:PendingRebootCheckFailed = $false
$script:ProgressUiIssueLogged = $false
$script:CurrentTaskLoggedError = $false
$script:CurrentTaskLoggedWarning = $false
$script:UiSync        = $null
$script:UiRunspace    = $null
$script:UiPipeline    = $null
$script:UiAsyncResult = $null
$script:CompletedTasks     = @()
$script:FailedTasks        = @()
$script:TaskResults        = @{}
$script:TaskList          = @()
$script:CheckpointAliases  = @{
    'phase1-restore-point'        = 'preflight-restore-point'
    'phase2-dark-mode'            = 'core-dark-mode'
    'phase3-bing-search'          = 'startui-bing-search'
    'phase3-taskbar-search'       = 'startui-search-box'
    'phase3-taskview-button'      = 'startui-task-view'
    'phase3-widgets'              = 'startui-widgets'
    'phase3-end-task'             = 'startui-end-task'
    'phase3-notifications'        = 'startui-notifications'
    'phase4-explorer-home'        = 'explorer-home-thispc'
    'phase4-explorer-onedrive'    = 'explorer-remove-onedrive'
    'phase4-explorer-autodiscovery'= 'explorer-auto-discovery'
}
$script:OOSUConfigUrl      = 'https://raw.githubusercontent.com/ChrisTitusTech/winutil/d0bde83333730a4536497451af747daba11e5039/ooshutup10_winutil_settings.cfg'
$script:OOSUSha256         = '01d64c068d6b949ff8b919c30d82ae0007ae3ad35006f63f04880005a33d51e9'
$script:TcpOptimizerSha256 = '0a49dc0d2ce725af347df632539b70afcfd22b38e285920b515143332a5511e9'
$script:WallpaperSourceUrl = 'https://drive.google.com/file/d/1YoHVPNm8sfC_ZOETNQP77JbDIlkHTH_O/view?usp=sharing'
$script:ResolvedWallpaperAssetUrl = $null
$script:SelfScriptContent  = $null

try {
    if ($null -ne $MyInvocation.MyCommand.ScriptBlock -and $null -ne $MyInvocation.MyCommand.ScriptBlock.Ast) {
        $script:SelfScriptContent = $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text
    }
} catch {
    $script:SelfScriptContent = $null
}

# ==============================================================================
# LOGGING
# ==============================================================================

$script:LogDirectoryEnsured = $false

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not $script:LogDirectoryEnsured) {
        $logDir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $script:LogDirectoryEnsured = $true
    }
    if ($Level -eq 'ERROR') {
        $script:CurrentTaskLoggedError = $true
    }
    if ($Level -eq 'WARN') {
        $script:CurrentTaskLoggedWarning = $true
    }
    try {
        Add-Content -Path $script:LogPath -Value $line -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("[Hunter] Failed to append to log file '$($script:LogPath)': $($_.Exception.Message)")
    }
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

function Add-RunInfrastructureIssue {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('WARN','ERROR')]
        [string]$Level = 'ERROR'
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    if ($script:RunInfrastructureIssues -notcontains $Message) {
        $script:RunInfrastructureIssues += $Message
    }

    Write-Log $Message $Level
}

# ==============================================================================
# DIRECTORY HELPER
# ==============================================================================

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-ProtectedDataAvailable {
    $protectedDataType = [System.Type]::GetType('System.Security.Cryptography.ProtectedData, System.Security', $false)
    if ($null -ne $protectedDataType) {
        return $true
    }

    Add-Type -AssemblyName 'System.Security' -ErrorAction Stop
    return $true
}

function Protect-StringForLocalMachine {
    param([Parameter(Mandatory)][string]$Value)

    Ensure-ProtectedDataAvailable | Out-Null
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

    return [Convert]::ToBase64String($protectedBytes)
}

function Unprotect-StringForLocalMachine {
    param([Parameter(Mandatory)][string]$Value)

    Ensure-ProtectedDataAvailable | Out-Null
    $protectedBytes = [Convert]::FromBase64String($Value)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function New-HunterRandomPassword {
    param([int]$Length = 24)

    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%&*?'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object 'System.Collections.Generic.List[char]'
        for ($i = 0; $i -lt [Math]::Max($Length, 16); $i++) {
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $index = [Math]::Abs([BitConverter]::ToUInt32($bytes, 0) % $alphabet.Length)
            [void]$chars.Add($alphabet[$index])
        }

        return (-join $chars)
    } finally {
        $rng.Dispose()
    }
}

function Set-HunterManagedLocalUserPassword {
    param([Parameter(Mandatory)][string]$Password)

    Ensure-Directory $script:SecretsRoot
    $payload = [ordered]@{
        Version   = 1
        UserName  = 'user'
        Password  = (Protect-StringForLocalMachine -Value $Password)
        UpdatedAt = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Depth 2 | Set-Content -Path $script:LocalUserSecretPath -Encoding UTF8 -Force
}

function Get-HunterManagedLocalUserPassword {
    if (-not [string]::IsNullOrWhiteSpace($env:HUNTER_LOCAL_USER_PASSWORD)) {
        Set-HunterManagedLocalUserPassword -Password $env:HUNTER_LOCAL_USER_PASSWORD
        return $env:HUNTER_LOCAL_USER_PASSWORD
    }

    if (-not (Test-Path $script:LocalUserSecretPath)) {
        return $null
    }

    try {
        $payload = Get-Content -Path $script:LocalUserSecretPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.Password)) {
            throw 'Managed local-user secret file does not contain a password payload.'
        }

        return (Unprotect-StringForLocalMachine -Value ([string]$payload.Password))
    } catch {
        Add-RunInfrastructureIssue -Message "Failed to load the managed local-user credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Resolve-HunterLocalUserPassword {
    param([bool]$UserExists)

    $storedPassword = Get-HunterManagedLocalUserPassword
    if (-not [string]::IsNullOrWhiteSpace($storedPassword)) {
        return [pscustomobject]@{
            Password     = $storedPassword
            WasGenerated = $false
            IsManaged    = $true
            Source       = if (-not [string]::IsNullOrWhiteSpace($env:HUNTER_LOCAL_USER_PASSWORD)) { 'Environment' } else { 'Stored' }
        }
    }

    if ($UserExists) {
        return $null
    }

    $generatedPassword = New-HunterRandomPassword
    Set-HunterManagedLocalUserPassword -Password $generatedPassword
    Write-Log "Generated and stored a machine-protected password for the managed local user." 'INFO'

    return [pscustomobject]@{
        Password     = $generatedPassword
        WasGenerated = $true
        IsManaged    = $true
        Source       = 'Generated'
    }
}

function Invoke-NativeCommandChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0)
    )

    & $FilePath @ArgumentList
    $exitCode = [int]$LASTEXITCODE
    if ($SuccessExitCodes -notcontains $exitCode) {
        throw "$FilePath exited with code $exitCode"
    }

    return $exitCode
}

function Start-ProcessChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0),
        [ValidateSet('Normal','Hidden','Minimized','Maximized')]
        [string]$WindowStyle = 'Normal'
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle $WindowStyle -ErrorAction Stop
    if ($null -eq $process) {
        throw "Failed to start process $FilePath"
    }

    if ($SuccessExitCodes -notcontains [int]$process.ExitCode) {
        throw "$FilePath exited with code $($process.ExitCode)"
    }

    return $process
}

function Show-YesNoDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [bool]$DefaultToNo = $true
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $defaultButton = if ($DefaultToNo) {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        } else {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        }

        $dialogResult = [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            $defaultButton
        )

        return ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        Write-Log "Failed to show confirmation dialog '$Title': $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function New-TaskSkipResult {
    param([string]$Reason = '')

    return [ordered]@{
        Success = $true
        Status  = 'Skipped'
        Reason  = $Reason
    }
}

function Get-TaskHandlerCompletionStatus {
    param(
        [object]$TaskResult,
        [bool]$LoggedWarning = $false
    )

    $explicitStatus = $null
    if ($TaskResult -is [hashtable] -and $TaskResult.ContainsKey('Status')) {
        $explicitStatus = [string]$TaskResult['Status']
    } elseif ($null -ne $TaskResult -and $TaskResult.PSObject.Properties['Status']) {
        $explicitStatus = [string]$TaskResult.Status
    }

    switch ($explicitStatus) {
        'Skipped' { return 'Skipped' }
        'CompletedWithWarnings' { return 'CompletedWithWarnings' }
        'Warning' { return 'CompletedWithWarnings' }
        'Completed' { return 'Completed' }
    }

    if ($LoggedWarning) {
        return 'CompletedWithWarnings'
    }

    return 'Completed'
}

function Initialize-InstallerJobHelpers {
    $helperContent = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function global:Get-PackageSlug {
    param([string]$PackageName)

    $slug = ($PackageName -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return 'package'
    }

    return $slug
}

function global:Get-DownloadedFileType {
    param([string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        '.exe' { return 'Exe' }
        '.msi' { return 'Msi' }
        '.zip' { return 'Zip' }
    }

    $buffer = New-Object byte[] 8
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

    try {
        $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
    } finally {
        $stream.Dispose()
    }

    if ($bytesRead -ge 2 -and $buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A) {
        return 'Exe'
    }

    if ($bytesRead -ge 4 -and $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and $buffer[2] -eq 0x03 -and $buffer[3] -eq 0x04) {
        return 'Zip'
    }

    if ($bytesRead -ge 8 -and
        $buffer[0] -eq 0xD0 -and
        $buffer[1] -eq 0xCF -and
        $buffer[2] -eq 0x11 -and
        $buffer[3] -eq 0xE0 -and
        $buffer[4] -eq 0xA1 -and
        $buffer[5] -eq 0xB1 -and
        $buffer[6] -eq 0x1A -and
        $buffer[7] -eq 0xE1) {
        return 'Msi'
    }

    return 'Unknown'
}

function global:Resolve-DownloadedFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Downloaded file not found: $Path"
    }

    $type = Get-DownloadedFileType -Path $Path
    $targetExtension = switch ($type) {
        'Exe' { '.exe' }
        'Msi' { '.msi' }
        'Zip' { '.zip' }
        default { '' }
    }

    if (-not [string]::IsNullOrWhiteSpace($targetExtension)) {
        $currentExtension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($currentExtension -ne $targetExtension) {
            $directory = Split-Path -Parent $Path
            $leafName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            if ([string]::IsNullOrWhiteSpace($leafName)) {
                $leafName = [System.IO.Path]::GetFileName($Path)
            }

            $resolvedPath = Join-Path $directory ($leafName + $targetExtension)
            Move-Item -Path $Path -Destination $resolvedPath -Force
            $Path = $resolvedPath
        }
    }

    return @{
        Path = $Path
        Type = $type
    }
}

function global:Confirm-InstallerSignature {
    param(
        [string]$PackageName,
        [string]$Path,
        [string]$ExpectedSha256 = ''
    )

    $resolvedFile = Resolve-DownloadedFile -Path $Path
    if ($resolvedFile.Type -notin @('Exe', 'Msi')) {
        return $resolvedFile.Path
    }

    $signature = Get-AuthenticodeSignature -FilePath $resolvedFile.Path
    if ($null -ne $signature -and [string]$signature.Status -eq 'Valid') {
        return $resolvedFile.Path
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actualHash = (Get-FileHash -Path $resolvedFile.Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $normalizedExpectedHash = $ExpectedSha256.ToLowerInvariant()
        if ($actualHash -eq $normalizedExpectedHash) {
            return $resolvedFile.Path
        }

        $signatureStatus = if ($null -eq $signature) { 'Unknown' } else { [string]$signature.Status }
        throw "$PackageName trust validation failed. Signature status: $signatureStatus. Expected SHA256 $normalizedExpectedHash but received $actualHash"
    }

    if ($null -eq $signature) {
        throw "$PackageName signature validation returned no signature data for $($resolvedFile.Path)"
    }

    throw "$PackageName signature validation failed with status $($signature.Status)"
}

function global:Invoke-WingetWithMutex {
    param(
        [string[]]$Arguments,
        [int]$WaitTimeoutSeconds = 1800
    )

    $mutex = [System.Threading.Mutex]::new($false, 'Global\HunterWingetInstall')
    $hasHandle = $false

    try {
        try {
            $hasHandle = $mutex.WaitOne([TimeSpan]::FromSeconds([Math]::Max($WaitTimeoutSeconds, 1)))
        } catch [System.Threading.AbandonedMutexException] {
            $hasHandle = $true
        }

        if (-not $hasHandle) {
            throw 'Timed out waiting for winget installation mutex.'
        }

        & winget @Arguments *> $null
        return $LASTEXITCODE
    } finally {
        if ($hasHandle) {
            try {
                [void]$mutex.ReleaseMutex()
            } catch {
                Write-Log "Warning: failed to release winget mutex: $_" 'WARN'
            }
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function global:Invoke-DirectInstallerWithMutex {
    param(
        [scriptblock]$Action,
        [int]$WaitTimeoutSeconds = 1800
    )

    $mutex = [System.Threading.Mutex]::new($false, 'Global\HunterDirectInstall')
    $hasHandle = $false

    try {
        try {
            $hasHandle = $mutex.WaitOne([TimeSpan]::FromSeconds([Math]::Max($WaitTimeoutSeconds, 1)))
        } catch [System.Threading.AbandonedMutexException] {
            $hasHandle = $true
        }

        if (-not $hasHandle) {
            throw 'Timed out waiting for direct installer mutex.'
        }

        & $Action
    } finally {
        if ($hasHandle) {
            try {
                [void]$mutex.ReleaseMutex()
            } catch {
                Write-Log "Warning: failed to release direct installer mutex: $_" 'WARN'
            }
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}
'@

    try {
        $script:InstallerJobHelperContent = $helperContent
        . ([scriptblock]::Create($helperContent))
    } catch {
        Write-Log "Failed to initialize installer job helpers: $_" 'ERROR'
        throw
    }
}

Initialize-InstallerJobHelpers

function Ensure-InstallerHelpersLoaded {
    if ($null -eq (Get-Command -Name 'Confirm-InstallerSignature' -ErrorAction SilentlyContinue)) {
        Initialize-InstallerJobHelpers
    }
}

function Format-ElapsedDuration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds)
    }

    return ('{0:00}:{1:00}' -f $Duration.Minutes, $Duration.Seconds)
}

# ==============================================================================
# REGISTRY HELPERS
# ==============================================================================

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [ValidateSet('DWord','String','QWord','Binary','ExpandString','MultiString')]
        [string]$Type = 'String'
    )
    try {
        $parentPath = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf $Path

        if (-not (Test-Path $Path)) {
            New-Item -Path $parentPath -Name $leaf -Force | Out-Null
        }

        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Log "Registry set: $Path\$Name = $Value ($Type)"
        return $true
    } catch {
        Write-Log "Failed to set registry $Path\$Name : $_" 'ERROR'
        return $false
    }
}

function Remove-RegistryKey {
    param([string]$Path)
    try {
        if (Test-Path $Path) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Registry key removed: $Path"
        }
    } catch {
        Write-Log "Failed to remove registry key $Path : $_" 'ERROR'
    }
}

function Test-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue
    )
    try {
        if (-not (Test-Path $Path)) {
            return $false
        }
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $prop) {
            return $false
        }
        if ($null -eq $ExpectedValue) {
            return $true
        }
        return $prop.$Name -eq $ExpectedValue
    } catch {
        return $false
    }
}

function Set-DwordForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name,
        [int]$Value
    )
    Set-RegistryValueForAllUsers -SubPath $SubPath -Name $Name -Value $Value -Type DWord
}

function Set-StringForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name,
        [string]$Value
    )
    Set-RegistryValueForAllUsers -SubPath $SubPath -Name $Name -Value $Value -Type String
}

function Remove-RegistryValueIfPresent {
    param(
        [string]$Path,
        [string]$Name
    )

    try {
        if (-not (Test-Path $Path)) {
            return
        }

        if ($null -eq (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)) {
            return
        }

        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
        Write-Log "Registry value removed: $Path\$Name"
    } catch {
        Write-Log "Failed to remove registry value $Path\$Name : $_" 'WARN'
    }
}

function Remove-RegistryValueForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name
    )

    Remove-RegistryValueIfPresent -Path "HKCU:\$SubPath" -Name $Name

    $defaultHiveLoaded = $false
    try {
        $profileListDefault = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name Default -ErrorAction SilentlyContinue).Default
        if ($profileListDefault) {
            $defaultHive = Join-Path $profileListDefault 'NTUSER.DAT'
        }
        if ([string]::IsNullOrEmpty($defaultHive) -or -not (Test-Path $defaultHive)) {
            $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        }
        if (Test-Path $defaultHive) {
            $defaultHiveLoaded = Invoke-RegHiveCommandWithRetry -Action Load -HiveName 'HKU\HunterDefault' -HivePath $defaultHive
            if (-not $defaultHiveLoaded) {
                Write-Log "Failed to load Default user hive to remove $SubPath\$Name" 'WARN'
                return
            }

            Remove-RegistryValueIfPresent -Path "Registry::HKEY_USERS\HunterDefault\$SubPath" -Name $Name
        }
    } catch {
        Write-Log "Failed to remove Default user registry value $SubPath\$Name : $_" 'WARN'
    } finally {
        if ($defaultHiveLoaded) {
            [GC]::Collect()
            if (-not (Invoke-RegHiveCommandWithRetry -Action Unload -HiveName 'HKU\HunterDefault')) {
                Write-Log "Failed to unload Default user hive after removing $SubPath\$Name" 'WARN'
            }
        }
    }
}

function Invoke-RegHiveCommandWithRetry {
    param(
        [ValidateSet('Load','Unload')]
        [string]$Action,
        [string]$HiveName,
        [string]$HivePath = '',
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($Action -eq 'Load') {
            & reg load $HiveName $HivePath 2>$null
        } else {
            & reg unload $HiveName 2>$null
        }

        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            $delayMs = [Math]::Min(2000, (150 * [Math]::Pow(2, ($attempt - 1))))
            Start-Sleep -Milliseconds ([int]$delayMs)
        }
    }

    return $false
}

function Set-RegistryValueForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name,
        [object]$Value,
        [ValidateSet('DWord','String')]
        [string]$Type
    )

    try {
        $currentUserPath = "HKCU:\$SubPath"
        $currentUserParentPath = Split-Path -Parent $currentUserPath
        $currentUserLeaf = Split-Path -Leaf $currentUserPath

        if (-not (Test-Path $currentUserPath)) {
            New-Item -Path $currentUserParentPath -Name $currentUserLeaf -Force | Out-Null
        }

        New-ItemProperty -Path $currentUserPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Log "$Type set for current user: $currentUserPath\$Name = $Value"
    } catch {
        Write-Log "Failed to set $Type for current user $SubPath\$Name : $_" 'ERROR'
    }

    $defaultHiveLoaded = $false
    try {
        $profileListDefault = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name Default -ErrorAction SilentlyContinue).Default
        if ($profileListDefault) {
            $defaultHive = Join-Path $profileListDefault 'NTUSER.DAT'
        }
        if ([string]::IsNullOrEmpty($defaultHive) -or -not (Test-Path $defaultHive)) {
            $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        }
        if (Test-Path $defaultHive) {
            $defaultHiveLoaded = Invoke-RegHiveCommandWithRetry -Action Load -HiveName 'HKU\HunterDefault' -HivePath $defaultHive
            if (-not $defaultHiveLoaded) {
                Write-Log "Failed to load Default user hive for $SubPath\$Name" 'WARN'
                return
            }

            $regPath = "Registry::HKEY_USERS\HunterDefault\$SubPath"
            $regParentPath = Split-Path -Parent $regPath
            $regLeaf = Split-Path -Leaf $regPath

            if (-not (Test-Path $regPath)) {
                New-Item -Path $regParentPath -Name $regLeaf -Force | Out-Null
            }

            New-ItemProperty -Path $regPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
            Write-Log "$Type set for Default user: $SubPath\$Name = $Value"
        }
    } catch {
        Write-Log "Failed to set $Type for Default user $SubPath\$Name : $_" 'ERROR'
    } finally {
        if ($defaultHiveLoaded) {
            [GC]::Collect()
            if (-not (Invoke-RegHiveCommandWithRetry -Action Unload -HiveName 'HKU\HunterDefault')) {
                Write-Log "Failed to unload Default user hive after updating $SubPath\$Name" 'WARN'
            }
        }
    }
}

function Set-DwordBatchForAllUsers {
    <#
    .SYNOPSIS
    Applies multiple DWORD registry values under the Default user hive in a single
    load/unload cycle. Each entry is a hashtable with SubPath, Name, and Value keys.
    #>
    param([hashtable[]]$Settings)

    if ($null -eq $Settings -or $Settings.Count -eq 0) { return }

    # Apply to current user first (no hive load needed)
    foreach ($setting in $Settings) {
        try {
            $currentUserPath = "HKCU:\$($setting.SubPath)"
            $parentPath = Split-Path -Parent $currentUserPath
            $leaf = Split-Path -Leaf $currentUserPath

            if (-not (Test-Path $currentUserPath)) {
                New-Item -Path $parentPath -Name $leaf -Force | Out-Null
            }

            New-ItemProperty -Path $currentUserPath -Name $setting.Name -Value $setting.Value -PropertyType DWord -Force | Out-Null
            Write-Log "DWord set for current user: $currentUserPath\$($setting.Name) = $($setting.Value)"
        } catch {
            Write-Log "Failed to set DWord for current user $($setting.SubPath)\$($setting.Name) : $_" 'ERROR'
        }
    }

    # Load Default hive once, apply all settings, unload once
    $defaultHiveLoaded = $false
    try {
        $profileListDefault = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name Default -ErrorAction SilentlyContinue).Default
        if ($profileListDefault) {
            $defaultHive = Join-Path $profileListDefault 'NTUSER.DAT'
        }
        if ([string]::IsNullOrEmpty($defaultHive) -or -not (Test-Path $defaultHive)) {
            $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        }
        if (Test-Path $defaultHive) {
            $defaultHiveLoaded = Invoke-RegHiveCommandWithRetry -Action Load -HiveName 'HKU\HunterDefault' -HivePath $defaultHive
            if (-not $defaultHiveLoaded) {
                Write-Log "Failed to load Default user hive for batch registry update" 'WARN'
                return
            }

            foreach ($setting in $Settings) {
                try {
                    $regPath = "Registry::HKEY_USERS\HunterDefault\$($setting.SubPath)"
                    $regParentPath = Split-Path -Parent $regPath
                    $regLeaf = Split-Path -Leaf $regPath

                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regParentPath -Name $regLeaf -Force | Out-Null
                    }

                    New-ItemProperty -Path $regPath -Name $setting.Name -Value $setting.Value -PropertyType DWord -Force | Out-Null
                    Write-Log "DWord set for Default user: $($setting.SubPath)\$($setting.Name) = $($setting.Value)"
                } catch {
                    Write-Log "Failed to set DWord for Default user $($setting.SubPath)\$($setting.Name) : $_" 'ERROR'
                }
            }
        }
    } catch {
        Write-Log "Failed during batch Default user hive update: $_" 'ERROR'
    } finally {
        if ($defaultHiveLoaded) {
            [GC]::Collect()
            if (-not (Invoke-RegHiveCommandWithRetry -Action Unload -HiveName 'HKU\HunterDefault')) {
                Write-Log "Failed to unload Default user hive after batch update" 'WARN'
            }
        }
    }
}

function Ensure-GlobalTimerResolutionRequestsEnabled {
    param([switch]$LogIfAlreadyEnabled)

    $kernelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    if (-not (Test-RegistryValue -Path $kernelPath -Name 'GlobalTimerResolutionRequests' -ExpectedValue 1)) {
        Set-RegistryValue -Path $kernelPath -Name 'GlobalTimerResolutionRequests' -Value 1 -Type DWord
        return $true
    }

    if ($LogIfAlreadyEnabled) {
        Write-Log 'Global timer resolution requests already enabled.' 'INFO'
    }

    return $false
}

# ==============================================================================
# PATH/FILE HELPERS
# ==============================================================================

function Remove-PathForce {
    param(
        [string]$Path,
        [switch]$WarnOnly
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        if (Test-Path $Path) {
            $allowedTargets = @(
                "$env:LOCALAPPDATA\Microsoft\OneDrive",
                "$env:ProgramData\Microsoft OneDrive",
                (Join-Path $script:ProgramFilesRoot 'Microsoft OneDrive'),
                "$env:LOCALAPPDATA\Microsoft\Teams"
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

            $resolvedPath = [System.IO.Path]::GetFullPath($Path)
            $isAllowed = $false
            foreach ($allowedTarget in $allowedTargets) {
                $resolvedAllowedTarget = [System.IO.Path]::GetFullPath($allowedTarget)
                if ($resolvedPath.StartsWith($resolvedAllowedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isAllowed = $true
                    break
                }
            }

            if (-not $isAllowed) {
                throw "Refusing privileged delete outside approved application cleanup roots: $Path"
            }

            $originalAcl = Get-Acl -Path $Path -ErrorAction SilentlyContinue

            try {
                & takeown /f "$Path" /r /d y 2>$null
                Start-Sleep -Milliseconds 200

                & icacls "$Path" /grant "${env:USERNAME}:(OI)(CI)F" /t 2>$null
                Start-Sleep -Milliseconds 200

                Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                Write-Log "Path removed with force: $Path"
            } catch {
                if ($null -ne $originalAcl -and (Test-Path $Path)) {
                    try {
                        Set-Acl -Path $Path -AclObject $originalAcl -ErrorAction Stop
                    } catch {
                        Write-Log "Failed to restore original ACLs for $Path : $_" 'WARN'
                    }
                }

                throw
            }
        }
    } catch {
        $level = if ($WarnOnly) { 'WARN' } else { 'ERROR' }
        Write-Log "Failed to force remove path $Path : $_" $level
    }
}

# ==============================================================================
# SERVICE HELPERS
# ==============================================================================

function Set-ServiceStartType {
    param(
        [string]$Name,
        [ValidateSet('Boot','System','Automatic','Disabled','Manual')]
        [string]$StartType
    )
    try {
        Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
        Write-Log "Service startup type set: $Name = $StartType"
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match 'Access is denied|cannot be configured|does not exist|was not found|The parameter is incorrect') {
            Write-Log "Skipped service startup type change for ${Name}: $errorMessage" 'WARN'
        } else {
            Write-Log "Failed to set service startup type $Name : $_" 'ERROR'
        }
    }
}

function Test-ServiceStartTypeMatch {
    param(
        [string]$Name,
        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$ExpectedStartType
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    try {
        $escapedName = $Name.Replace("'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return $true
        }

        $actualStartType = switch ($service.StartMode) {
            'Auto' { 'Automatic' }
            'Manual' { 'Manual' }
            'Disabled' { 'Disabled' }
            default { [string]$service.StartMode }
        }

        return ($actualStartType -eq $ExpectedStartType)
    } catch {
        return $false
    }
}

function Test-ServiceAutomaticDelayedStart {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $serviceKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    return (
        (Test-RegistryValue -Path $serviceKeyPath -Name 'Start' -ExpectedValue 2) -and
        (Test-RegistryValue -Path $serviceKeyPath -Name 'DelayedAutostart' -ExpectedValue 1)
    )
}

function Stop-ServiceIfPresent {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    try {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return
        }

        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            Write-Log "Service stopped: $Name" 'INFO'
        }
    } catch {
        Write-Log "Failed to stop service ${Name}: $($_.Exception.Message)" 'WARN'
    }
}

function Test-ShouldDisablePrintSpooler {
    try {
        $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
        return ($printers.Count -eq 0)
    } catch {
        Write-Log "Failed to enumerate printers for Spooler safety check: $($_.Exception.Message)" 'WARN'
        return $false
    }
}


function Disable-ScheduledTaskIfPresent {
    param(
        [string]$TaskPath,
        [string]$TaskName,
        [string]$DisplayName = $TaskName
    )

    if ([string]::IsNullOrWhiteSpace($TaskPath) -or [string]::IsNullOrWhiteSpace($TaskName)) {
        return $false
    }

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return $false
        }

        if ($task.State -eq 'Disabled') {
            Write-Log "Scheduled task already disabled: $DisplayName" 'INFO'
            return $true
        }

        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log "Scheduled task disabled: $DisplayName" 'INFO'
        return $true
    } catch {
        Write-Log "Failed to disable scheduled task ${DisplayName}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Disable-WindowsOptionalFeatureIfPresent {
    param(
        [string]$DisplayName,
        [string[]]$CandidateNames,
        [switch]$SkipOnHyperVGuest
    )

    if ($SkipOnHyperVGuest -and $script:IsHyperVGuest) {
        Write-Log "Hyper-V guest detected, skipping $DisplayName optional feature disable." 'INFO'
        return $true
    }

    if ($null -eq $CandidateNames -or $CandidateNames.Count -eq 0) {
        return $false
    }

    try {
        $resolvedFeature = $null
        foreach ($candidateName in $CandidateNames) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $candidateName -ErrorAction SilentlyContinue
            if ($null -ne $feature) {
                $resolvedFeature = $feature
                break
            }
        }

        if ($null -eq $resolvedFeature) {
            Write-Log "$DisplayName optional feature not present. Skipping." 'INFO'
            return $true
        }

        if ([string]$resolvedFeature.State -notin @('Enabled', 'Enable Pending')) {
            Write-Log "$DisplayName optional feature already disabled." 'INFO'
            return $true
        }

        Disable-WindowsOptionalFeature -Online -FeatureName $resolvedFeature.FeatureName -NoRestart -ErrorAction Stop | Out-Null
        Write-Log "$DisplayName optional feature disabled." 'INFO'
        return $true
    } catch {
        Write-Log "Failed to disable $DisplayName optional feature: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Set-DirectXGlobalPreferenceValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $existingPairs = [ordered]@{}
    $currentSerializedValue = ''

    try {
        $currentSettings = Get-ItemProperty -Path $path -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue
        if ($null -ne $currentSettings) {
            $currentSerializedValue = [string]$currentSettings.DirectXUserGlobalSettings
        }
    } catch {
        $currentSerializedValue = ''
    }

    foreach ($segment in @($currentSerializedValue -split ';')) {
        if ($segment -notmatch '^([^=]+)=(.*)$') {
            continue
        }

        $existingPairs[$Matches[1]] = $Matches[2]
    }

    $existingPairs[$Key] = $Value
    $serializedValue = (($existingPairs.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f $_.Key, $_.Value
    }) -join ';')

    if (-not [string]::IsNullOrWhiteSpace($serializedValue)) {
        $serializedValue += ';'
    }

    Set-RegistryValue -Path $path -Name 'DirectXUserGlobalSettings' -Value $serializedValue -Type String
}

function Invoke-BCDEditBestEffort {
    param(
        [string[]]$ArgumentList,
        [string]$Description
    )

    try {
        $process = Start-Process -FilePath 'bcdedit.exe' -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($null -eq $process) {
            throw 'bcdedit.exe did not return a process handle.'
        }

        if ([int]$process.ExitCode -eq 0) {
            Write-Log $Description 'INFO'
            return $true
        }

        Write-Log "$Description returned exit code $($process.ExitCode)." 'WARN'
        return $false
    } catch {
        Write-Log "Failed to update boot configuration for ${Description}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# ==============================================================================
# APPX HELPERS
# ==============================================================================

function Remove-AppxPatterns {
    param([string[]]$Patterns)
    if ($null -eq $Patterns -or $Patterns.Count -eq 0) { return }

    $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

    foreach ($pattern in $Patterns) {
        try {
            foreach ($package in @($installedPackages |
                    Where-Object { $_.PSObject.Properties['Name'] -and $_.Name -like $pattern })) {
                try {
                    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Log "AppX package removed: $($package.Name)"
                } catch {
                    $errorMessage = $_.Exception.Message
                    if ($errorMessage -match '0x80070032|part of Windows and cannot be uninstalled|The request is not supported') {
                        Write-Log "Skipping built-in AppX package $($package.Name): $errorMessage" 'INFO'
                    } else {
                        Write-Log "Failed to remove AppX package $($package.Name) : $_" 'WARN'
                    }
                }
            }

            foreach ($package in @($provisionedPackages |
                    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $pattern })) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop
                    Write-Log "AppX provisioned package removed: $($package.DisplayName)"
                } catch {
                    $errorMessage = $_.Exception.Message
                    if ($errorMessage -match '0x80070032|part of Windows and cannot be uninstalled|The request is not supported') {
                        Write-Log "Skipping built-in AppX provisioned package $($package.DisplayName): $errorMessage" 'INFO'
                    } else {
                        Write-Log "Failed to remove AppX provisioned package $($package.DisplayName) : $_" 'WARN'
                    }
                }
            }
        } catch {
            Write-Log "Failed to process AppX pattern $pattern : $_" 'ERROR'
        }
    }
}

function Test-AppxPatternExists {
    param([string[]]$Patterns)

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return $false
    }

    $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

    foreach ($pattern in @($Patterns)) {
        if (@($installedPackages | Where-Object { $_.PSObject.Properties['Name'] -and $_.Name -like $pattern }).Count -gt 0) {
            return $true
        }
        if (@($provisionedPackages | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $pattern }).Count -gt 0) {
            return $true
        }
    }

    return $false
}

# ==============================================================================
# DOWNLOAD HELPER
# ==============================================================================

function Download-File {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = 900,
        [bool]$Force = $false
    )
    if (Test-Path $Destination) {
        if ($Force) {
            Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        } else {
            $existingFile = Get-Item -Path $Destination -ErrorAction SilentlyContinue
            if ($null -ne $existingFile -and $existingFile.Length -gt 0) {
                Write-Log "Download skipped (already exists): $Destination"
                return $Destination
            }

            Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    Ensure-Directory (Split-Path -Parent $Destination)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Log "Failed to enforce TLS 1.2 for download client: $_" 'WARN'
    }

    $ProgressPreference = 'SilentlyContinue'

    $downloadErrors = @()
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue

    if ($null -ne $curl) {
        try {
            & $curl.Source -L --fail --silent --show-error --output $Destination $Url
            if ($LASTEXITCODE -ne 0) {
                throw "curl.exe exited with code $LASTEXITCODE"
            }

            $curlFile = Get-Item -Path $Destination -ErrorAction Stop
            if ($curlFile.Length -le 0) {
                throw 'Downloaded file is empty'
            }

            Write-Log "File downloaded: $Destination"
            return $Destination
        } catch {
            $downloadErrors += "curl.exe: $($_.Exception.Message)"
            Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing `
            -MaximumRedirection 10 `
            -TimeoutSec $TimeoutSec `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Hunter/2.0' } `
            -ErrorAction Stop

        $webFile = Get-Item -Path $Destination -ErrorAction Stop
        if ($webFile.Length -le 0) {
            throw 'Downloaded file is empty'
        }

        Write-Log "File downloaded: $Destination"
        return $Destination
    } catch {
        $downloadErrors += "Invoke-WebRequest: $($_.Exception.Message)"
        Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        $joinedErrors = $downloadErrors -join ' | '
        Write-Log "Failed to download $Url : $joinedErrors" 'ERROR'
        throw
    }
}

function Get-TcpOptimizerDownloadPath {
    return (Join-Path $script:DownloadDir 'TCPOptimizer.exe')
}

function Get-OOSUDownloadPath {
    return (Join-Path $script:DownloadDir 'OOSU10.exe')
}

function Get-OOSUConfigPath {
    return (Join-Path $script:HunterRoot 'ooshutup10_winutil_settings.cfg')
}

function Get-ResolvedWallpaperAssetUrl {
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedWallpaperAssetUrl)) {
        return $script:ResolvedWallpaperAssetUrl
    }

    $script:ResolvedWallpaperAssetUrl = Resolve-WallpaperAssetUrl
    return $script:ResolvedWallpaperAssetUrl
}

function Get-WallpaperAssetPath {
    param([string]$WallpaperUrl = (Get-ResolvedWallpaperAssetUrl))

    if ([string]::IsNullOrWhiteSpace($WallpaperUrl)) {
        return $null
    }

    $wallpaperRoot = Join-Path $script:HunterRoot 'Assets'
    Ensure-Directory $wallpaperRoot

    $wallpaperExtension = [System.IO.Path]::GetExtension(([uri]$WallpaperUrl).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($wallpaperExtension)) {
        $wallpaperExtension = '.jpg'
    }

    return (Join-Path $wallpaperRoot "hunter-wallpaper$wallpaperExtension")
}

function Start-ExternalAssetPrefetchJob {
    param(
        [string]$AssetKey,
        [string]$AssetName,
        [string]$Url,
        [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($AssetKey) -or
        [string]::IsNullOrWhiteSpace($AssetName) -or
        [string]::IsNullOrWhiteSpace($Url) -or
        [string]::IsNullOrWhiteSpace($Destination)) {
        return $false
    }

    $existingFile = Get-Item -Path $Destination -ErrorAction SilentlyContinue
    if ($null -ne $existingFile -and $existingFile.Length -gt 0) {
        $script:PrefetchedExternalAssets[$AssetKey] = $true
        Write-Log "External asset already present, skipping prefetch: $AssetName" 'INFO'
        return $false
    }

    $activeJob = @($script:ExternalAssetPrefetchJobs | Where-Object {
        $_.AssetKey -eq $AssetKey -and $_.Job.State -notin @('Completed', 'Failed', 'Stopped')
    } | Select-Object -First 1)
    if ($activeJob.Count -gt 0) {
        Write-Log "External asset prefetch already running: $AssetName" 'INFO'
        return $false
    }

    Ensure-Directory (Split-Path -Parent $Destination)

    $job = Start-Job -ScriptBlock {
        param(
            [string]$AssetKey,
            [string]$AssetName,
            [string]$Url,
            [string]$Destination
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch { }

        $tempPath = "$Destination.prefetch"

        try {
            if (Test-Path $tempPath) {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
            }

            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($null -ne $curl) {
                & $curl.Source -L --fail --silent --show-error --retry 2 --connect-timeout 15 -o $tempPath $Url
                if ($LASTEXITCODE -ne 0) {
                    throw "curl.exe exited with code $LASTEXITCODE"
                }
            } else {
                Invoke-WebRequest `
                    -Uri $Url `
                    -OutFile $tempPath `
                    -UseBasicParsing `
                    -MaximumRedirection 10 `
                    -TimeoutSec 300 `
                    -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Hunter/2.0' } `
                    -ErrorAction Stop
            }

            $downloadedFile = Get-Item -Path $tempPath -ErrorAction Stop
            if ($downloadedFile.Length -le 0) {
                throw 'Downloaded file is empty'
            }

            $finalFile = Get-Item -Path $Destination -ErrorAction SilentlyContinue
            if ($null -ne $finalFile -and $finalFile.Length -gt 0) {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{
                    AssetKey    = $AssetKey
                    AssetName   = $AssetName
                    Destination = $Destination
                    Success     = $true
                    Message     = 'Already downloaded by another task.'
                }
            }

            Move-Item -Path $tempPath -Destination $Destination -Force

            return [pscustomobject]@{
                AssetKey    = $AssetKey
                AssetName   = $AssetName
                Destination = $Destination
                Success     = $true
                Message     = 'Prefetch completed.'
            }
        } catch {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                AssetKey    = $AssetKey
                AssetName   = $AssetName
                Destination = $Destination
                Success     = $false
                Message     = $_.Exception.Message
            }
        }
    } -ArgumentList $AssetKey, $AssetName, $Url, $Destination

    $script:ExternalAssetPrefetchJobs += [pscustomobject]@{
        AssetKey    = $AssetKey
        AssetName   = $AssetName
        Destination = $Destination
        Job         = $job
        StartedAt   = Get-Date
    }

    Write-Log "Started external asset prefetch: $AssetName" 'INFO'
    return $true
}

function Invoke-CollectCompletedExternalAssetPrefetchJobs {
    try {
        if ($script:ExternalAssetPrefetchJobs.Count -eq 0) {
            return
        }

        $remainingJobs = @()
        foreach ($jobInfo in @($script:ExternalAssetPrefetchJobs)) {
            if ($jobInfo.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
                $remainingJobs += $jobInfo
                continue
            }

            $elapsed = Format-ElapsedDuration -Duration ((Get-Date) - $jobInfo.StartedAt)
            $jobReceiveErrors = @()
            $jobOutput = @(Receive-Job -Job $jobInfo.Job -Keep -ErrorAction Continue -ErrorVariable +jobReceiveErrors)
            $result = $null

            foreach ($outputItem in $jobOutput) {
                if ($null -eq $outputItem) {
                    continue
                }

                $propertyNames = @($outputItem.PSObject.Properties | Select-Object -ExpandProperty Name)
                if (($propertyNames -contains 'AssetKey') -and
                    ($propertyNames -contains 'Success') -and
                    ($propertyNames -contains 'Message')) {
                    $result = $outputItem
                }
            }

            if ($null -eq $result) {
                $finalFile = Get-Item -Path $jobInfo.Destination -ErrorAction SilentlyContinue
                if ($null -ne $finalFile -and $finalFile.Length -gt 0) {
                    $result = [pscustomobject]@{
                        AssetKey    = $jobInfo.AssetKey
                        AssetName   = $jobInfo.AssetName
                        Destination = $jobInfo.Destination
                        Success     = $true
                        Message     = 'Prefetch completed.'
                    }
                } else {
                    $receiveMessage = if ($jobReceiveErrors.Count -gt 0) {
                        ($jobReceiveErrors | ForEach-Object { $_.ToString() }) -join ' | '
                    } else {
                        "Job finished in state $($jobInfo.Job.State) without returning a result."
                    }

                    $result = [pscustomobject]@{
                        AssetKey    = $jobInfo.AssetKey
                        AssetName   = $jobInfo.AssetName
                        Destination = $jobInfo.Destination
                        Success     = $false
                        Message     = $receiveMessage
                    }
                }
            }

            if ($result.Success) {
                $script:PrefetchedExternalAssets[$result.AssetKey] = $true
                Write-Log "Background asset ready: $($jobInfo.AssetName) after $elapsed - $($result.Message)" 'SUCCESS'
            } else {
                Write-Log "Background asset prefetch failed: $($jobInfo.AssetName) after $elapsed - $($result.Message)" 'WARN'
            }

            Remove-Job -Job $jobInfo.Job -Force -ErrorAction SilentlyContinue
        }

        $script:ExternalAssetPrefetchJobs = @($remainingJobs)
    } catch {
        Write-Log "Failed to collect external asset prefetch jobs: $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-PrefetchExternalAssets {
    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log 'Starting phase-8 external asset prefetch jobs in the background...' 'INFO'

        # Never block phase progression on wallpaper URL resolution during kickoff.
        $wallpaperUrl = $script:ResolvedWallpaperAssetUrl
        $wallpaperPath = $null
        if (-not [string]::IsNullOrWhiteSpace($wallpaperUrl)) {
            $wallpaperPath = Get-WallpaperAssetPath -WallpaperUrl $wallpaperUrl
        } else {
            Write-Log 'Wallpaper URL is not cached yet; deferring wallpaper prefetch to avoid blocking phase progression.' 'INFO'
        }

        $startedJobs = 0

        $tcpOptimizerPath = Get-TcpOptimizerDownloadPath
        if (-not (Test-Path $tcpOptimizerPath)) {
            if (Start-ExternalAssetPrefetchJob -AssetKey 'tcp-optimizer' -AssetName 'TCP Optimizer' -Url 'https://www.speedguide.net/files/TCPOptimizer.exe' -Destination $tcpOptimizerPath) {
                $startedJobs++
            }
        }

        $oosuPath = Get-OOSUDownloadPath
        if (-not (Test-Path $oosuPath)) {
            if (Start-ExternalAssetPrefetchJob -AssetKey 'oosu-binary' -AssetName 'O&O ShutUp10' -Url 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -Destination $oosuPath) {
                $startedJobs++
            }
        }

        $oosuConfigPath = Get-OOSUConfigPath
        if (Start-ExternalAssetPrefetchJob -AssetKey 'oosu-config' -AssetName 'O&O ShutUp10 preset' -Url $script:OOSUConfigUrl -Destination $oosuConfigPath) {
            $startedJobs++
        }

        if (-not [string]::IsNullOrWhiteSpace($wallpaperUrl) -and -not [string]::IsNullOrWhiteSpace($wallpaperPath)) {
            if (Start-ExternalAssetPrefetchJob -AssetKey 'wallpaper' -AssetName 'Wallpaper' -Url $wallpaperUrl -Destination $wallpaperPath) {
                $startedJobs++
            }
        }

        $activePrefetchJobs = @($script:ExternalAssetPrefetchJobs | Where-Object {
            $_.Job.State -notin @('Completed', 'Failed', 'Stopped')
        }).Count

        Write-Log "Phase-8 external asset prefetch continues in background: $startedJobs started this pass, $activePrefetchJobs active total." 'INFO'
        return $true
    } catch {
        Write-Log "External asset prefetch kickoff failed (will retry during phase 8): $($_.Exception.Message)" 'WARN'
        return $true
    }
}

function Get-GitHubLatestReleaseAsset {
    param(
        [string]$Owner,
        [string]$Repo,
        [string[]]$NamePatterns
    )

    if ($null -eq $NamePatterns -or $NamePatterns.Count -eq 0) {
        throw 'At least one release asset name pattern is required.'
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Log "Failed to enforce TLS 1.2 for GitHub release lookup: $_" 'WARN'
    }

    $ProgressPreference = 'SilentlyContinue'

    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    $latestPageUrl = "https://github.com/$Owner/$Repo/releases/latest"
    $headers = @{
        Accept       = 'application/vnd.github+json'
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Hunter/2.0'
    }

    function Invoke-GitHubApiJson {
        param(
            [string]$Uri,
            [hashtable]$Headers,
            [int]$TimeoutSec = 60
        )

        $ProgressPreference = 'SilentlyContinue'
        $maxAttempts = [Math]::Max(1, [int]$script:GitHubApiMaxAttempts)
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                return Invoke-RestMethod -Uri $Uri -Headers $Headers -MaximumRedirection 5 -TimeoutSec $TimeoutSec -ErrorAction Stop
            } catch {
                $errorMessage = $_.Exception.Message
                $statusCode = $null

                try {
                    if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                } catch {}

                $isRateLimited = ($errorMessage -match 'rate limit') -or ($statusCode -eq 403)
                if ($attempt -ge $maxAttempts -or $isRateLimited) {
                    throw
                }

                $delaySec = [Math]::Min(
                    10,
                    ([int]$script:GitHubApiBaseDelaySec * [Math]::Pow(2, ($attempt - 1)))
                )
                Write-Log "GitHub API request failed for $Uri (attempt $attempt/$maxAttempts). Retrying in $delaySec second(s): $errorMessage" 'WARN'
                Start-Sleep -Seconds $delaySec
            }
        }
    }

    try {
        $release = Invoke-GitHubApiJson -Uri $apiUrl -Headers $headers -TimeoutSec 60
        foreach ($asset in @($release.assets)) {
            foreach ($pattern in $NamePatterns) {
                if ($asset.name -imatch $pattern) {
                    return @{
                        Url      = $asset.browser_download_url
                        FileName = $asset.name
                    }
                }
            }
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match 'rate limit|403') {
            Write-Log "GitHub release API unavailable or rate limited for ${Owner}/${Repo}. Falling back to the latest release page: $errorMessage" 'WARN'
        } else {
            Write-Log "GitHub release API lookup failed for ${Owner}/${Repo}: $errorMessage" 'WARN'
        }
    }

    try {
        $releasePage = Invoke-WebRequest -Uri $latestPageUrl -Headers @{ 'User-Agent' = $headers['User-Agent'] } -MaximumRedirection 5 -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        foreach ($link in @($releasePage.Links)) {
            $href = [string]$link.href
            if ([string]::IsNullOrWhiteSpace($href)) {
                continue
            }

            $fileName = [System.IO.Path]::GetFileName(($href -split '\?')[0])
            foreach ($pattern in $NamePatterns) {
                if ($fileName -imatch $pattern) {
                    $resolvedUrl = if ($href -match '^https?://') { $href } else { "https://github.com$href" }
                    return @{
                        Url      = $resolvedUrl
                        FileName = $fileName
                    }
                }
            }
        }
    } catch {
        Write-Log "GitHub release page lookup failed for ${Owner}/${Repo}: $_" 'WARN'
    }

    throw "No release asset matched the requested patterns for $Owner/$Repo."
}

function Get-ParsecDownloadSpec {
    return @{
        Url      = 'https://builds.parsec.app/package/parsec-windows.exe'
        FileName = 'ParsecSetup.exe'
    }
}

function Get-ParsecExecutablePath {
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Parsec\parsecd.exe'),
        (Join-Path $env:ProgramFiles 'Parsec\parsec.exe'),
        (Join-Path $env:ProgramFiles 'Parsec\bin\parsecd.exe'),
        (Join-Path $env:ProgramFiles 'Parsec\bin\parsec.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\parsecd.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\parsec.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\bin\parsecd.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\bin\parsec.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Parsec\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Parsec\parsec.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\parsec.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\bin\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\bin\parsec.exe'),
        (Join-Path $env:APPDATA 'Parsec\parsecd.exe'),
        (Join-Path $env:APPDATA 'Parsec\parsec.exe'),
        (Join-Path $env:APPDATA 'Parsec\bin\parsecd.exe'),
        (Join-Path $env:APPDATA 'Parsec\bin\parsec.exe'),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Parsec\Parsec.lnk')),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Parsec\Parsec.lnk')),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Parsec.lnk')),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Parsec.lnk')),
        (Find-ShortcutTargetByPattern -Directories (Get-StartMenuShortcutDirectories) -Patterns @('Parsec*.lnk')),
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'parsecd.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Parsec' } |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'parsec.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Parsec' } |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path @(
                (Join-Path $env:ProgramFiles 'Parsec'),
                (Join-Path ${env:ProgramFiles(x86)} 'Parsec'),
                (Join-Path $env:LOCALAPPDATA 'Parsec'),
                (Join-Path $env:APPDATA 'Parsec')
            ) -Recurse -File -Filter 'parsecd.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path @(
                (Join-Path $env:ProgramFiles 'Parsec'),
                (Join-Path ${env:ProgramFiles(x86)} 'Parsec'),
                (Join-Path $env:LOCALAPPDATA 'Parsec'),
                (Join-Path $env:APPDATA 'Parsec')
            ) -Recurse -File -Filter 'parsec.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName)
    )

    return (Find-FirstExistingPath -CandidatePaths $candidatePaths)
}

function Get-FurMarkDownloadSpec {
    return @{
        Url      = 'https://geeks3d.com/dl/get/831'
        FileName = 'FurMarkSetup.exe'
    }
}

function Get-PeaZipDownloadSpec {
    $existingSpec = Get-Variable -Scope Script -Name 'PeaZipDownloadSpec' -ErrorAction SilentlyContinue
    if ($null -ne $existingSpec -and $null -ne $existingSpec.Value) {
        return $script:PeaZipDownloadSpec
    }

    try {
        $script:PeaZipDownloadSpec = Get-GitHubLatestReleaseAsset `
            -Owner 'peazip' `
            -Repo 'PeaZip' `
            -NamePatterns @(
                '^peazip-.*\.win64\.exe$',
                '^peazip-.*\.windows\.x64\.exe$'
            )
    } catch {
        Write-Log "Falling back to pinned PeaZip release asset: $_" 'WARN'
        $script:PeaZipDownloadSpec = @{
            Url      = 'https://github.com/peazip/PeaZip/releases/latest/download/peazip-10.9.0.WIN64.exe'
            FileName = 'peazip-10.9.0.WIN64.exe'
        }
    }

    return $script:PeaZipDownloadSpec
}

function Get-WinaeroTweakerDownloadSpec {
    return @{
        Url      = 'https://winaerotweaker.com/download/winaerotweaker.zip'
        FileName = 'WinaeroTweaker.zip'
    }
}

function Get-BraveDownloadSpec {
    return @{
        Url      = 'https://laptop-updates.brave.com/latest/winx64'
        FileName = 'BraveSetup.exe'
    }
}

function Get-SteamDownloadSpec {
    return @{
        Url      = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
        FileName = 'SteamSetup.exe'
    }
}

function Get-FFmpegDownloadSpec {
    return @{
        Url      = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        FileName = 'ffmpeg-release-essentials.zip'
    }
}

function Get-YtDlpDownloadSpec {
    return @{
        Url      = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
        FileName = 'yt-dlp.exe'
    }
}

function Get-CrystalDiskMarkDownloadSpec {
    return @{
        Url      = 'https://sourceforge.net/projects/crystaldiskmark/files/latest/download'
        FileName = 'CrystalDiskMarkSetup.exe'
    }
}

function Get-PowerShell7DownloadSpec {
    try {
        return (Get-GitHubLatestReleaseAsset `
            -Owner 'PowerShell' `
            -Repo 'PowerShell' `
            -NamePatterns @('^PowerShell-.*-win-x64\.msi$'))
    } catch {
        Write-Log "Falling back to pinned PowerShell 7 release asset: $_" 'WARN'
        return @{
            Url      = 'https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/PowerShell-7.5.4-win-x64.msi'
            FileName = 'PowerShell-7.5.4-win-x64.msi'
        }
    }
}

function Get-PowerShell7ExecutablePath {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    return (Find-FirstExistingPath -CandidatePaths @(
        $(if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) { Join-Path $PSHOME 'pwsh.exe' } else { $null }),
        'C:\Program Files\PowerShell\7\pwsh.exe',
        'C:\Program Files\PowerShell\pwsh.exe',
        $(if ($null -ne $command) { $command.Source } else { $null })
    ))
}

function Get-BraveExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\Programs\BraveSoftware\Brave-Browser\Application\brave.exe",
        'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
        (Get-Command brave.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ))
}

function Get-SteamExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        'C:\Program Files (x86)\Steam\steam.exe',
        'C:\Program Files\Steam\steam.exe'
    ))
}

function Get-FFmpegExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        (Join-Path $script:HunterRoot 'Tools\FFmpeg\ffmpeg.exe'),
        (Join-Path $script:HunterRoot 'Packages\FFmpeg\ffmpeg.exe'),
        (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -File -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path $script:HunterRoot -Recurse -File -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
    ))
}

function Get-YtDlpExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        (Join-Path $script:HunterRoot 'Tools\yt-dlp\yt-dlp.exe'),
        (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -File -Filter 'yt-dlp.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
        (Get-Command yt-dlp.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ))
}

function Resolve-CachedExecutablePath {
    param(
        [Parameter(Mandatory)][string]$CacheKey,
        [Parameter(Mandatory)][scriptblock]$Resolver,
        [int]$RetryDelaySeconds = 10
    )

    if ($script:ExecutableResolverCache.ContainsKey($CacheKey)) {
        $cachedPath = [string]$script:ExecutableResolverCache[$CacheKey]
        if (-not [string]::IsNullOrWhiteSpace($cachedPath) -and (Test-Path $cachedPath)) {
            return $cachedPath
        }

        $script:ExecutableResolverCache.Remove($CacheKey) | Out-Null
    }

    if ($script:ExecutableResolverNextAttemptAt.ContainsKey($CacheKey)) {
        $nextAttemptAt = $script:ExecutableResolverNextAttemptAt[$CacheKey]
        if ($nextAttemptAt -is [datetime] -and (Get-Date) -lt $nextAttemptAt) {
            return $null
        }
    }

    $resolvedPath = & $Resolver
    if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path $resolvedPath)) {
        $script:ExecutableResolverCache[$CacheKey] = $resolvedPath
        $script:ExecutableResolverNextAttemptAt.Remove($CacheKey) | Out-Null
        return $resolvedPath
    }

    $script:ExecutableResolverNextAttemptAt[$CacheKey] = (Get-Date).AddSeconds([Math]::Max($RetryDelaySeconds, 2))
    return $null
}

function Get-CrystalDiskMarkExecutablePath {
    return (Resolve-CachedExecutablePath -CacheKey 'crystaldiskmark' -RetryDelaySeconds 10 -Resolver {
        Find-FirstExistingPath -CandidatePaths @(
            'C:\Program Files\CrystalDiskMark\DiskMark64.exe',
            'C:\Program Files\CrystalDiskMark\CrystalDiskMark.exe',
            'C:\Program Files\CrystalDiskMark8\DiskMark64.exe',
            'C:\Program Files\CrystalDiskMark8\CrystalDiskMark.exe',
            'C:\Program Files\CrystalDiskMark9\DiskMark64.exe',
            'C:\Program Files\CrystalDiskMark9\CrystalDiskMark.exe',
            'C:\Program Files (x86)\CrystalDiskMark\DiskMark64.exe',
            'C:\Program Files (x86)\CrystalDiskMark\CrystalDiskMark.exe',
            (Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -File -Filter 'DiskMark64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        )
    })
}

function Get-CinebenchR23ExecutablePath {
    return (Resolve-CachedExecutablePath -CacheKey 'cinebench-r23' -RetryDelaySeconds 10 -Resolver {
        $candidatePaths = @(
            (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps') -File -Filter 'Cinebench*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path 'C:\Program Files\WindowsApps' -Directory -Filter 'Maxon.Cinebench*' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -File -Filter 'Cinebench*.exe' -ErrorAction SilentlyContinue } |
                Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'Cinebench*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
            'C:\Program Files\Maxon Cinema 4D\Cinebench.exe',
            'C:\Program Files\Maxon Cinema 4D\CinebenchR23\Cinebench.exe',
            'C:\Program Files\Maxon\CinebenchR23\Cinebench.exe'
        )

        return (Find-FirstExistingPath -CandidatePaths $candidatePaths)
    })
}

function Test-IsLegacyHunterCinebenchPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $legacyRoot = Join-Path $script:HunterRoot 'Packages\Cinebench-R23'
    return $Path.StartsWith($legacyRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-LegacyHunterCinebenchPayload {
    $legacyRoot = Join-Path $script:HunterRoot 'Packages\Cinebench-R23'
    if (-not (Test-Path $legacyRoot)) {
        return
    }

    try {
        Remove-Item -Path $legacyRoot -Recurse -Force -ErrorAction Stop
        Write-Log 'Removed legacy Hunter Cinebench ZIP payload so the Microsoft Store Cinebench install can take precedence.' 'INFO'
    } catch {
        Write-Log "Failed to remove legacy Hunter Cinebench payload: $($_.Exception.Message)" 'WARN'
    }
}

function Get-FurMarkExecutablePath {
    return (Resolve-CachedExecutablePath -CacheKey 'furmark' -RetryDelaySeconds 10 -Resolver {
        Find-FirstExistingPath -CandidatePaths @(
            'C:\Program Files (x86)\Geeks3D\Benchmarks\FurMark\FurMark.exe',
            'C:\Program Files\Geeks3D\Benchmarks\FurMark\FurMark.exe',
            'C:\Program Files (x86)\Geeks3D\FurMark 2\FurMark.exe',
            'C:\Program Files\Geeks3D\FurMark 2\FurMark.exe',
            'C:\Program Files (x86)\Geeks3D\FurMark\FurMark.exe',
            'C:\Program Files\Geeks3D\FurMark\FurMark.exe',
            (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\FurMark.lnk')),
            (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'FurMark*.exe' -and $_.FullName -match 'FurMark|Geeks3D' } |
                Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'FurMark*.exe' -and $_.FullName -match 'FurMark|Geeks3D' } |
                Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -File -Filter 'FurMark.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'FurMark|Geeks3D' } |
                Select-Object -First 1 -ExpandProperty FullName)
        )
    })
}

function Get-PeaZipExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        'C:\Program Files\PeaZip\peazip.exe',
        'C:\Program Files (x86)\PeaZip\peazip.exe',
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PeaZip.lnk')),
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'peazip.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'PeaZip' } |
            Select-Object -First 1 -ExpandProperty FullName)
    ))
}

function Get-WinaeroTweakerExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        (Join-Path $script:HunterRoot 'Packages\Winaero-Tweaker\Winaero Tweaker.exe'),
        (Join-Path $script:HunterRoot 'Packages\Winaero-Tweaker\WinaeroTweaker.exe'),
        (Get-ChildItem -Path (Join-Path $script:HunterRoot 'Packages') -Recurse -File -Filter 'Winaero*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
    ))
}

function Get-InstallTargetCatalog {
    return @(
        @{
            PackageId                 = 'powershell7'
            PackageName               = 'PowerShell 7'
            WingetId                  = 'Microsoft.PowerShell'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-PowerShell7DownloadSpec }
            InstallerArgs             = '/qn /norestart'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-PowerShell7ExecutablePath }
            ShortcutName              = 'PowerShell 7'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*PowerShell*', '*pwsh*')
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'brave'
            PackageName               = 'Brave'
            WingetId                  = 'Brave.Brave'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-BraveDownloadSpec }
            InstallerArgs             = '/silent /install'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-BraveExecutablePath }
            ShortcutName              = 'Brave Browser'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*Brave*')
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'parsec'
            PackageName               = 'Parsec'
            WingetId                  = 'Parsec.Parsec'
            SkipWinget                = $true
            GetDownloadSpec           = { Get-ParsecDownloadSpec }
            InstallerArgs             = '/silent /norun /percomputer'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @(13)
            RefreshDownloadOnFailure  = $false
            AllowDirectDownloadFallback = $true
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-ParsecExecutablePath }
            VerificationTimeoutSeconds = 180
            ShortcutName              = 'Parsec'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*Parsec*')
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'steam'
            PackageName               = 'Steam'
            WingetId                  = 'Valve.Steam'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-SteamDownloadSpec }
            InstallerArgs             = '/S'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-SteamExecutablePath }
            ShortcutName              = 'Steam'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*Steam*')
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'ffmpeg'
            PackageName               = 'FFmpeg'
            WingetId                  = 'Gyan.FFmpeg'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-FFmpegDownloadSpec }
            InstallerArgs             = ''
            InstallKind               = 'Archive'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $true
            PathProbe                 = 'ffmpeg.exe'
            GetExecutable             = { Get-FFmpegExecutablePath }
            ShortcutName              = 'FFmpeg'
            CreateDesktopShortcut     = $false
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'ytdlp'
            PackageName               = 'yt-dlp'
            WingetId                  = 'yt-dlp.yt-dlp'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-YtDlpDownloadSpec }
            InstallerArgs             = ''
            InstallKind               = 'Portable'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $true
            PathProbe                 = ''
            GetExecutable             = { Get-YtDlpExecutablePath }
            ShortcutName              = 'yt-dlp'
            CreateDesktopShortcut     = $false
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'crystaldiskmark'
            PackageName               = 'CrystalDiskMark'
            WingetId                  = 'CrystalDewWorld.CrystalDiskMark'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-CrystalDiskMarkDownloadSpec }
            InstallerArgs             = '/S'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-CrystalDiskMarkExecutablePath }
            ShortcutName              = 'CrystalDiskMark'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'cinebench-r23'
            PackageName               = 'Cinebench R23'
            WingetId                  = 'Maxon.CinebenchR23'
            WingetSource              = 'winget'
            WingetUseId               = $true
            SkipWinget                = $false
            GetDownloadSpec           = { $null }
            InstallerArgs             = ''
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AllowDirectDownloadFallback = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-CinebenchR23ExecutablePath }
            ShortcutName              = 'Cinebench R23'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'furmark'
            PackageName               = 'FurMark'
            WingetId                  = 'Geeks3D.FurMark.2'
            SkipWinget                = $true
            GetDownloadSpec           = { Get-FurMarkDownloadSpec }
            InstallerArgs             = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $true
            AllowDirectDownloadFallback = $true
            SkipSignatureValidation   = $true
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-FurMarkExecutablePath }
            ShortcutName              = 'FurMark'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'peazip'
            PackageName               = 'PeaZip'
            WingetId                  = 'Giorgiotani.Peazip'
            SkipWinget                = $false
            GetDownloadSpec           = { Get-PeaZipDownloadSpec }
            InstallerArgs             = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AllowDirectDownloadFallback = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-PeaZipExecutablePath }
            ShortcutName              = 'PeaZip'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            PackageId                 = 'winaero-tweaker'
            PackageName               = 'Winaero Tweaker'
            WingetId                  = ''
            SkipWinget                = $true
            GetDownloadSpec           = { Get-WinaeroTweakerDownloadSpec }
            InstallerArgs             = ''
            InstallKind               = 'Archive'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = { Get-WinaeroTweakerExecutablePath }
            ShortcutName              = 'Winaero Tweaker'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        }
    )
}

function Stop-WindowedProcessesByPattern {
    param([string[]]$Patterns)

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return
    }

    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        foreach ($pattern in @($Patterns)) {
            if ($process.ProcessName -notlike $pattern) {
                continue
            }

            try {
                if ($process.MainWindowHandle -ne 0 -or -not [string]::IsNullOrWhiteSpace($process.MainWindowTitle)) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    Write-Log "Closed post-install app window: $($process.ProcessName)"
                }
            } catch {
                Write-Log "Failed to close post-install app window $($process.ProcessName) : $_" 'WARN'
            }

            break
        }
    }
}

function Wait-ForExecutablePath {
    param(
        [scriptblock]$Resolver,
        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $resolvedPath = & $Resolver
        if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path $resolvedPath)) {
            return $resolvedPath
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return (& $Resolver)
}

function Resolve-InstallTargetExecutablePaths {
    param(
        [hashtable[]]$Targets,
        [hashtable]$ResultsByPackageId
    )

    $resolvedPaths = @{}
    $pendingTargets = [System.Collections.ArrayList]::new()

    foreach ($target in @($Targets)) {
        $result = $ResultsByPackageId[$target.PackageId]
        if ($null -eq $result -or -not $result.Success) {
            continue
        }

        if ($script:PostInstallCompletion.ContainsKey($target.PackageId) -and [bool]$script:PostInstallCompletion[$target.PackageId]) {
            continue
        }

        if ($target.ContainsKey('ExistingExecutablePath') -and
            -not [string]::IsNullOrWhiteSpace($target.ExistingExecutablePath) -and
            (Test-Path $target.ExistingExecutablePath)) {
            $resolvedPaths[$target.PackageId] = $target.ExistingExecutablePath
            continue
        }

        $timeoutSeconds = if ($target.ContainsKey('VerificationTimeoutSeconds') -and [int]$target.VerificationTimeoutSeconds -gt 0) {
            [int]$target.VerificationTimeoutSeconds
        } else {
            45
        }

        [void]$pendingTargets.Add([pscustomobject]@{
            Target    = $target
            Deadline  = (Get-Date).AddSeconds($timeoutSeconds)
        })
    }

    while ($pendingTargets.Count -gt 0) {
        $remainingTargets = [System.Collections.ArrayList]::new()
        $madeProgress = $false

        foreach ($pendingTarget in @($pendingTargets)) {
            $target = $pendingTarget.Target
            $resolvedPath = & $target.GetExecutable

            if ($target.PackageId -eq 'cinebench-r23' -and (Test-IsLegacyHunterCinebenchPath -Path $resolvedPath)) {
                $resolvedPath = $null
            }

            if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path $resolvedPath)) {
                $resolvedPaths[$target.PackageId] = $resolvedPath
                $madeProgress = $true
                continue
            }

            if ((Get-Date) -lt $pendingTarget.Deadline) {
                [void]$remainingTargets.Add($pendingTarget)
            }
        }

        if ($remainingTargets.Count -eq 0) {
            break
        }

        $pendingTargets = $remainingTargets
        if (-not $madeProgress) {
            Start-Sleep -Seconds 2
        }
    }

    return $resolvedPaths
}

function Complete-InstalledApp {
    param(
        [string]$PackageName,
        [string]$ExecutablePath,
        [string]$ShortcutName = '',
        [bool]$PinToTaskbar = $false,
        [string[]]$TaskbarDisplayPatterns,
        [string[]]$PostInstallWindowPatterns = @(),
        [bool]$CreateDesktopShortcut = $true
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or -not (Test-Path $ExecutablePath)) {
        Write-Log "$PackageName executable not detected after installation." 'ERROR'
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ShortcutName)) {
        $ShortcutName = $PackageName
    }

    $shortcutPaths = Ensure-CachedAppShortcutSet `
        -ShortcutName $ShortcutName `
        -TargetPath $ExecutablePath `
        -Description $PackageName `
        -CreateDesktopShortcut $CreateDesktopShortcut

    if ($PinToTaskbar) {
        $displayPatterns = if ($null -eq $TaskbarDisplayPatterns -or $TaskbarDisplayPatterns.Count -eq 0) {
            @("*$ShortcutName*")
        } else {
            $TaskbarDisplayPatterns
        }

        $pinCandidatePaths = @($ExecutablePath) + @($shortcutPaths)
        if ($script:TaskbarReconcilePending) {
            Write-Log "$PackageName taskbar pin queued for deferred taskbar pin reconciliation." 'INFO'
        } elseif (-not (Invoke-EnsureTaskbarAction -Action Pin -DisplayPatterns $displayPatterns -Paths $pinCandidatePaths)) {
            Write-Log "$PackageName taskbar pin shell verb was unavailable or ignored by Windows. Falling back to deferred taskbar pin reconciliation." 'INFO'
            $script:TaskbarReconcilePending = $true
            Write-Log "$PackageName taskbar pin queued for deferred taskbar pin reconciliation." 'INFO'
        }
    }

    Stop-WindowedProcessesByPattern -Patterns $PostInstallWindowPatterns
    return $true
}

function Add-MachinePathEntry {
    param([string]$PathEntry)

    if ([string]::IsNullOrWhiteSpace($PathEntry) -or -not (Test-Path $PathEntry)) {
        return
    }

    try {
        $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $entries = @()

        if (-not [string]::IsNullOrWhiteSpace($currentPath)) {
            $entries = $currentPath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }

        if ($entries -contains $PathEntry) {
            return
        }

        $newPath = (($entries + $PathEntry) | Select-Object -Unique) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        $env:Path = (($env:Path.Split(';') + $PathEntry) | Select-Object -Unique) -join ';'
        Write-Log "PATH entry added: $PathEntry"
    } catch {
        Write-Log "Failed to add PATH entry $PathEntry : $_" 'ERROR'
    }
}

# ==============================================================================
# SHORTCUT/STARTUP HELPERS
# ==============================================================================

function Remove-ShortcutsByPattern {
    param(
        [string[]]$Directories,
        [string[]]$Patterns
    )
    if ($null -eq $Directories -or $Directories.Count -eq 0 -or $null -eq $Patterns -or $Patterns.Count -eq 0) { return }

    foreach ($dir in $Directories) {
        try {
            if (Test-Path $dir) {
                foreach ($file in @(Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue)) {
                    if ($file.Extension -notin @('.lnk', '.url')) { continue }

                    foreach ($pattern in $Patterns) {
                        if ($file.Name -notlike $pattern) { continue }

                        try {
                            Remove-Item -Path $file.FullName -Force
                            Write-Log "Shortcut removed: $($file.FullName)"
                        } catch {
                            Write-Log "Failed to remove shortcut $($file.FullName) : $_" 'ERROR'
                        }

                        break
                    }
                }
            }
        } catch {
            Write-Log "Failed to process shortcuts in $dir : $_" 'ERROR'
        }
    }
}

function Test-ShortcutPatternExists {
    param(
        [string[]]$Directories,
        [string[]]$Patterns
    )

    foreach ($dir in @($Directories)) {
        if (-not (Test-Path $dir)) { continue }

        foreach ($file in @(Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($file.Extension -notin @('.lnk', '.url')) { continue }

            foreach ($pattern in @($Patterns)) {
                if ($file.Name -like $pattern) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Remove-TaskbarPinsByPattern {
    param(
        [string[]]$Patterns,
        [string[]]$Paths
    )
    if (($null -eq $Patterns -or $Patterns.Count -eq 0) -and ($null -eq $Paths -or $Paths.Count -eq 0)) { return }

    try {
        $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        if (Test-Path $taskbarPath) {
            foreach ($file in @(Get-ChildItem -Path $taskbarPath -Recurse -File -ErrorAction SilentlyContinue)) {
                if ($file.Extension -ne '.lnk') { continue }

                $removePin = $false
                foreach ($pattern in @($Patterns)) {
                    if ($file.Name -like $pattern) {
                        $removePin = $true
                        break
                    }
                }

                if (-not $removePin) {
                    $targetPath = Get-ShortcutTargetPath -ShortcutPath $file.FullName
                    foreach ($candidatePath in @($Paths)) {
                        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
                            continue
                        }

                        if ($targetPath -ieq $candidatePath) {
                            $removePin = $true
                            break
                        }
                    }
                }

                if (-not $removePin) {
                    continue
                }

                try {
                    Remove-Item -Path $file.FullName -Force
                    Write-Log "Taskbar pin removed: $($file.FullName)"
                } catch {
                    Write-Log "Failed to remove taskbar pin $($file.FullName) : $_" 'ERROR'
                }
            }
        }
    } catch {
        Write-Log "Failed to process taskbar pins : $_" 'ERROR'
    }
}

function Get-NormalizedShellVerbName {
    param([object]$Verb)
    if ($null -eq $Verb) { return '' }

    $verbName = [string]$Verb.Name
    if ([string]::IsNullOrWhiteSpace($verbName)) { return '' }

    return (($verbName -replace '&', '') -replace '\s+', ' ').Trim()
}

function Find-ShellVerbByPattern {
    param(
        [object]$Item,
        [string[]]$Patterns
    )

    foreach ($verb in @($Item.Verbs())) {
        $verbName = Get-NormalizedShellVerbName -Verb $verb
        foreach ($pattern in @($Patterns)) {
            if ($verbName -like $pattern) {
                return $verb
            }
        }
    }

    return $null
}

function Get-DesktopShortcutDirectories {
    return @(
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop"
    )
}

function Get-StartMenuShortcutDirectories {
    return @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        $script:AllUsersStartMenuProgramsPath
    )
}

function Find-FirstExistingPath {
    param([string[]]$CandidatePaths)

    foreach ($candidatePath in @($CandidatePaths) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    return $null
}

function New-WindowsShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$IconLocation = ''
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not (Test-Path $TargetPath)) {
        return $false
    }

    try {
        if (Test-Path $ShortcutPath) {
            $existingShell = New-Object -ComObject WScript.Shell
            $existingShortcut = $existingShell.CreateShortcut($ShortcutPath)
            if (($existingShortcut.TargetPath -ieq $TargetPath) -and ([string]$existingShortcut.Arguments -eq $Arguments)) {
                return $true
            }
        }

        Ensure-Directory (Split-Path -Parent $ShortcutPath)
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
        $shortcut.Description = $Description
        $shortcut.IconLocation = if ([string]::IsNullOrWhiteSpace($IconLocation)) { $TargetPath } else { $IconLocation }
        $shortcut.Save()
        Write-Log "Shortcut created: $ShortcutPath"
        return $true
    } catch {
        Write-Log "Failed to create shortcut $ShortcutPath : $_" 'ERROR'
        return $false
    }
}

function Find-ExistingShortcutByTarget {
    param(
        [string[]]$Directories,
        [string]$TargetPath,
        [string]$Arguments = ''
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not (Test-Path $TargetPath)) {
        return $null
    }

    foreach ($directory in @($Directories) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        if (-not (Test-Path $directory)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -Path $directory -Recurse -File -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($file.FullName)
                if (($shortcut.TargetPath -ieq $TargetPath) -and ([string]$shortcut.Arguments -eq $Arguments)) {
                    return $file.FullName
                }
            } catch {
                continue
            }
        }
    }

    return $null
}

function Ensure-DesktopShortcut {
    param(
        [string]$ShortcutName,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$IconLocation = ''
    )

    $desktopPath = Join-Path $env:USERPROFILE 'Desktop'
    $shortcutPath = Join-Path $desktopPath "$ShortcutName.lnk"
    return (New-WindowsShortcut -ShortcutPath $shortcutPath -TargetPath $TargetPath -Arguments $Arguments -Description $Description -IconLocation $IconLocation)
}

function Ensure-AppShortcutSet {
    param(
        [string]$ShortcutName,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$IconLocation = '',
        [bool]$CreateDesktopShortcut = $true
    )

    $shortcutPaths = @()
    $desktopShortcutPath = Join-Path (Join-Path $env:USERPROFILE 'Desktop') "$ShortcutName.lnk"
    $managedStartMenuShortcutPath = Join-Path $script:AllUsersStartMenuProgramsPath "$ShortcutName.lnk"

    if ($CreateDesktopShortcut) {
        $existingDesktopShortcut = Find-ExistingShortcutByTarget `
            -Directories (Get-DesktopShortcutDirectories) `
            -TargetPath $TargetPath `
            -Arguments $Arguments

        if (-not [string]::IsNullOrWhiteSpace($existingDesktopShortcut)) {
            $shortcutPaths += $existingDesktopShortcut
        } elseif (New-WindowsShortcut -ShortcutPath $desktopShortcutPath -TargetPath $TargetPath -Arguments $Arguments -Description $Description -IconLocation $IconLocation) {
            $shortcutPaths += $desktopShortcutPath
        }
    }

    $existingStartMenuShortcut = Find-ExistingShortcutByTarget `
        -Directories (Get-StartMenuShortcutDirectories) `
        -TargetPath $TargetPath `
        -Arguments $Arguments

    if (-not [string]::IsNullOrWhiteSpace($existingStartMenuShortcut)) {
        $shortcutPaths += $existingStartMenuShortcut
    }

    # Always maintain a stable all-users shortcut for taskbar policy XML.
    if (New-WindowsShortcut -ShortcutPath $managedStartMenuShortcutPath -TargetPath $TargetPath -Arguments $Arguments -Description $Description -IconLocation $IconLocation) {
        $shortcutPaths += $managedStartMenuShortcutPath
    }

    return @($shortcutPaths | Select-Object -Unique)
}

function Get-AppShortcutSetCacheKey {
    param(
        [string]$ShortcutName,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$IconLocation = ''
    )

    return @($ShortcutName, $TargetPath, $Arguments, $Description, $IconLocation) -join '|'
}

function Ensure-CachedAppShortcutSet {
    param(
        [string]$ShortcutName,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$IconLocation = '',
        [bool]$CreateDesktopShortcut = $true
    )

    $cacheKey = Get-AppShortcutSetCacheKey `
        -ShortcutName $ShortcutName `
        -TargetPath $TargetPath `
        -Arguments $Arguments `
        -Description $Description `
        -IconLocation $IconLocation

    $cachedEntry = $null
    if ($script:AppShortcutSetCache.ContainsKey($cacheKey)) {
        $cachedEntry = $script:AppShortcutSetCache[$cacheKey]
        if (-not $CreateDesktopShortcut -or [bool]$cachedEntry.CreateDesktopShortcut) {
            return @($cachedEntry.ShortcutPaths)
        }
    }

    $shortcutPaths = Ensure-AppShortcutSet `
        -ShortcutName $ShortcutName `
        -TargetPath $TargetPath `
        -Arguments $Arguments `
        -Description $Description `
        -IconLocation $IconLocation `
        -CreateDesktopShortcut $CreateDesktopShortcut

    $script:AppShortcutSetCache[$cacheKey] = [pscustomobject]@{
        ShortcutPaths         = @($shortcutPaths | Select-Object -Unique)
        CreateDesktopShortcut = ($CreateDesktopShortcut -or ($null -ne $cachedEntry -and [bool]$cachedEntry.CreateDesktopShortcut))
    }

    return @($script:AppShortcutSetCache[$cacheKey].ShortcutPaths)
}

function Get-TaskbarPinnedInstallTargets {
    return @((Get-InstallTargetCatalog | Where-Object { $_.PinToTaskbar }))
}

function Get-PreparedTaskbarPinnedApps {
    param([bool]$LogMissingExecutable = $false)

    $preparedPins = @()
    foreach ($pinSpec in @(Get-TaskbarPinnedInstallTargets)) {
        $executablePath = & $pinSpec.GetExecutable
        if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path $executablePath)) {
            if ($LogMissingExecutable) {
                Write-Log "$($pinSpec.PackageName) executable not found - skipping taskbar pin." 'WARN'
            }
            continue
        }

        $shortcutPaths = Ensure-CachedAppShortcutSet `
            -ShortcutName $pinSpec.ShortcutName `
            -TargetPath $executablePath `
            -Description $pinSpec.PackageName `
            -CreateDesktopShortcut $false

        $managedLinkPath = Join-Path $script:AllUsersStartMenuProgramsPath "$($pinSpec.ShortcutName).lnk"
        $linkPath = Find-FirstExistingPath -CandidatePaths (@($managedLinkPath) + @($shortcutPaths))
        if ([string]::IsNullOrWhiteSpace($linkPath)) {
            continue
        }

        $preparedPins += [pscustomobject]@{
            PinSpec        = $pinSpec
            ExecutablePath = $executablePath
            ShortcutPaths  = @($shortcutPaths)
            LinkPath       = $linkPath
        }
    }

    return @($preparedPins)
}

function Get-DefaultTaskbarCleanupDefinition {
    return [pscustomobject]@{
        EdgePatterns = @('*Edge*', '*Microsoft Edge*', '*msedge*')
        StorePatterns = @('*Microsoft Store*')
        EdgePaths = @(
            'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
        )
        StorePaths = @(
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Store.lnk",
            (Join-Path $script:AllUsersStartMenuProgramsPath 'Microsoft Store.lnk')
        )
        ShortcutDirectories = @(((Get-DesktopShortcutDirectories) + (Get-StartMenuShortcutDirectories)) | Select-Object -Unique)
    }
}

function Invoke-RemoveDefaultTaskbarSurfaceArtifacts {
    param([bool]$RemoveEdgeShortcuts = $false)

    $cleanupDefinition = Get-DefaultTaskbarCleanupDefinition

    if (-not $script:DefaultTaskbarPinsRemoved) {
        Invoke-EnsureTaskbarAction -Action Unpin -DisplayPatterns $cleanupDefinition.EdgePatterns -Paths $cleanupDefinition.EdgePaths | Out-Null
        Invoke-EnsureTaskbarAction -Action Unpin -DisplayPatterns $cleanupDefinition.StorePatterns -Paths $cleanupDefinition.StorePaths | Out-Null
        Remove-TaskbarPinsByPattern `
            -Patterns ($cleanupDefinition.EdgePatterns + $cleanupDefinition.StorePatterns) `
            -Paths ($cleanupDefinition.EdgePaths + $cleanupDefinition.StorePaths)
        $script:DefaultTaskbarPinsRemoved = $true
    }

    if ($RemoveEdgeShortcuts -and -not $script:EdgeShortcutsRemoved) {
        if (Test-ShortcutPatternExists -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns) {
            Remove-ShortcutsByPattern -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns
        }
        $script:EdgeShortcutsRemoved = $true
    }

    return $cleanupDefinition
}

function Clear-StaleStartCustomizationPolicies {
    try {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
        $currentUserPolicyPath = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        $hadFailure = $false

        Remove-RegistryValueIfPresent -Path $policyPath -Name 'ConfigureStartPins'
        Remove-RegistryValueIfPresent -Path $currentUserPolicyPath -Name 'ConfigureStartPins'
        Remove-RegistryValueIfPresent -Path $policyPath -Name 'StartLayoutFile'
        Remove-RegistryValueIfPresent -Path $policyPath -Name 'LockedStartLayout'

        try {
            $cleanupTask = Get-ScheduledTask -TaskName 'Hunter-TaskbarPolicyCleanup' -ErrorAction SilentlyContinue
            if ($null -ne $cleanupTask) {
                Unregister-ScheduledTask -TaskName 'Hunter-TaskbarPolicyCleanup' -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Log "Removed stale scheduled task 'Hunter-TaskbarPolicyCleanup'." 'INFO'
            }
        } catch {
            $hadFailure = $true
            Write-Log "Failed to remove stale taskbar cleanup task: $($_.Exception.Message)" 'ERROR'
        }

        try {
            $instance = Get-CimInstance `
                -Namespace 'root\cimv2\mdm\dmmap' `
                -ClassName 'MDM_Policy_Config01_Start02' `
                -Filter "ParentID='./Vendor/MSFT/Policy/Config' AND InstanceID='Start'" `
                -ErrorAction Stop

            if ($null -ne $instance) {
                $changed = $false

                if (($instance.PSObject.Properties.Name -contains 'ConfigureStartPins') -and
                    -not [string]::IsNullOrWhiteSpace([string]$instance.ConfigureStartPins)) {
                    $instance.ConfigureStartPins = ''
                    $changed = $true
                }

                if (($instance.PSObject.Properties.Name -contains 'StartLayout') -and
                    -not [string]::IsNullOrWhiteSpace([string]$instance.StartLayout)) {
                    $instance.StartLayout = ''
                    $changed = $true
                }

                if (($instance.PSObject.Properties.Name -contains 'NoPinningToTaskbar') -and
                    ([int]$instance.NoPinningToTaskbar -ne 0)) {
                    $instance.NoPinningToTaskbar = 0
                    $changed = $true
                }

                if ($changed) {
                    Set-CimInstance -CimInstance $instance -ErrorAction Stop | Out-Null
                    Write-Log 'Cleared stale managed Start policy values from the WMI bridge.' 'INFO'
                }
            }
        } catch {
            Write-Log "Managed Start policy WMI cleanup was not available: $($_.Exception.Message)" 'WARN'
        }

        foreach ($leftoverValue in @(
                @{ Path = $policyPath; Name = 'ConfigureStartPins' },
                @{ Path = $currentUserPolicyPath; Name = 'ConfigureStartPins' },
                @{ Path = $policyPath; Name = 'StartLayoutFile' },
                @{ Path = $policyPath; Name = 'LockedStartLayout' }
            )) {
            if (Test-Path $leftoverValue.Path) {
                try {
                    $currentItem = Get-ItemProperty -Path $leftoverValue.Path -ErrorAction Stop
                    if ($null -ne $currentItem.PSObject.Properties[$leftoverValue.Name]) {
                        $hadFailure = $true
                        Write-Log "Stale Start customization policy is still present: $($leftoverValue.Path)\$($leftoverValue.Name)" 'ERROR'
                    }
                } catch [System.Management.Automation.ItemNotFoundException] {
                } catch {
                    $hadFailure = $true
                    Write-Log "Failed to verify Start customization policy cleanup for $($leftoverValue.Path)\$($leftoverValue.Name): $($_.Exception.Message)" 'ERROR'
                }
            }
        }

        if ($hadFailure) {
            return $false
        }

        return $true
    } catch {
        Write-Log "Failed to clear stale Start customization policies: $_" 'ERROR'
        return $false
    }
}

function Get-ShortcutTargetPath {
    param([string]$ShortcutPath)

    try {
        if ([System.IO.Path]::GetExtension($ShortcutPath).ToLowerInvariant() -ne '.lnk' -or -not (Test-Path $ShortcutPath)) {
            return $null
        }

        $shell = New-Object -ComObject WScript.Shell
        return $shell.CreateShortcut($ShortcutPath).TargetPath
    } catch {
        return $null
    }
}

function Find-ShortcutTargetByPattern {
    param(
        [string[]]$Directories,
        [string[]]$Patterns
    )

    foreach ($directory in @($Directories) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        if (-not (Test-Path $directory)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -Path $directory -Recurse -File -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            foreach ($pattern in @($Patterns)) {
                if ($file.Name -notlike $pattern) {
                    continue
                }

                $targetPath = Get-ShortcutTargetPath -ShortcutPath $file.FullName
                if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                    return $targetPath
                }
            }
        }
    }

    return $null
}

function Get-ShellItemFromPath {
    param(
        [object]$Shell,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    try {
        $parentPath = Split-Path -Parent $Path
        $leafName = Split-Path -Leaf $Path
        $folder = $Shell.NameSpace($parentPath)
        if ($null -eq $folder) {
            return $null
        }

        return $folder.ParseName($leafName)
    } catch {
        return $null
    }
}

function Get-TaskbarTargetItems {
    param(
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    $shell = New-Object -ComObject Shell.Application
    $items = @()
    $appsFolder = $null

    try {
        $appsFolder = $shell.NameSpace('shell:AppsFolder')
        if ($null -ne $appsFolder) {
            foreach ($item in @($appsFolder.Items())) {
                foreach ($pattern in @($DisplayPatterns)) {
                    if ($item.Name -like $pattern) {
                        $items += $item
                        break
                    }
                }
            }
        }
    } catch {
        Write-Log "Failed to inspect AppsFolder taskbar targets: $_" 'WARN'
    }

    foreach ($path in @($Paths) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        $item = Get-ShellItemFromPath -Shell $shell -Path $path
        if ($null -ne $item) {
            $items += $item
        }
    }

    if ($null -ne $appsFolder -and [System.Runtime.InteropServices.Marshal]::IsComObject($appsFolder)) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($appsFolder)
    }

    if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    return $items
}

function Test-TaskbarPinnedByShell {
    param(
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    foreach ($item in @(Get-TaskbarTargetItems -DisplayPatterns $DisplayPatterns -Paths $Paths)) {
        $verb = Find-ShellVerbByPattern -Item $item -Patterns $script:TaskbarUnpinVerbPatterns

        if ($null -ne $verb) {
            return $true
        }
    }

    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $taskbarPath) {
        foreach ($file in @(Get-ChildItem -Path $taskbarPath -Recurse -File -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            foreach ($pattern in @($DisplayPatterns)) {
                if ($file.BaseName -like $pattern -or $file.Name -like $pattern) {
                    return $true
                }
            }

            $targetPath = Get-ShortcutTargetPath -ShortcutPath $file.FullName
            if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                foreach ($candidatePath in @($Paths)) {
                    if ([string]::IsNullOrWhiteSpace($candidatePath)) {
                        continue
                    }

                    if ($targetPath -ieq $candidatePath) {
                        return $true
                    }
                }
            }
        }
    }

    return $false
}

function Invoke-TaskbarAction {
    param(
        [ValidateSet('Pin','Unpin')]
        [string]$Action,
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    $currentlyPinned = Test-TaskbarPinnedByShell -DisplayPatterns $DisplayPatterns -Paths $Paths
    if ($Action -eq 'Pin' -and $currentlyPinned) {
        return $true
    }

    if ($Action -eq 'Unpin' -and -not $currentlyPinned) {
        return $true
    }

    $verbPatterns = if ($Action -eq 'Pin') { $script:TaskbarPinVerbPatterns } else { $script:TaskbarUnpinVerbPatterns }
    $actionTaken = $false

    foreach ($item in @(Get-TaskbarTargetItems -DisplayPatterns $DisplayPatterns -Paths $Paths)) {
        try {
            $verb = Find-ShellVerbByPattern -Item $item -Patterns $verbPatterns
            if ($null -eq $verb) {
                continue
            }

            $verb.DoIt()
            $actionTaken = $true
            Write-Log "Taskbar $($Action.ToLowerInvariant()) requested for $($item.Name)"
        } catch {
            Write-Log "Failed to $($Action.ToLowerInvariant()) taskbar target $($item.Name) : $_" 'WARN'
        }
    }

    if (-not $actionTaken) {
        return $false
    }

    $expectedPinned = ($Action -eq 'Pin')
    $deadline = (Get-Date).AddSeconds($script:TaskbarStateTimeoutSec)
    do {
        $isPinnedAfterAction = Test-TaskbarPinnedByShell -DisplayPatterns $DisplayPatterns -Paths $Paths
        if ($isPinnedAfterAction -eq $expectedPinned) {
            return $true
        }

        Start-Sleep -Milliseconds $script:TaskbarStatePollIntervalMs
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Invoke-EnsureTaskbarAction {
    param(
        [ValidateSet('Pin','Unpin')]
        [string]$Action,
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    if ($Action -eq 'Pin' -and $script:TaskbarReconcilePending) {
        return $false
    }

    # Attempt 1: Shell verb approach
    if (Invoke-TaskbarAction -Action $Action -DisplayPatterns $DisplayPatterns -Paths $Paths) {
        return $true
    }

    # Attempt 2: Restart Start Surface and retry Shell verb
    Restart-StartSurface
    $startSurfaceDeadline = (Get-Date).AddSeconds($script:StartSurfaceReadyTimeoutSec)
    do {
        $startSurfaceReady = @(
            Get-Process -Name 'StartMenuExperienceHost', 'ShellExperienceHost' -ErrorAction SilentlyContinue
        ).Count -gt 0

        if ($startSurfaceReady) {
            break
        }

        Start-Sleep -Milliseconds $script:TaskbarStatePollIntervalMs
    } while ((Get-Date) -lt $startSurfaceDeadline)

    if (Invoke-TaskbarAction -Action $Action -DisplayPatterns $DisplayPatterns -Paths $Paths) {
        return $true
    }

    return $false
}

# ==============================================================================
# APPSFOLDER HELPERS
# ==============================================================================

function Invoke-AppsFolderActionByPatterns {
    param(
        [string[]]$Patterns,
        [string[]]$VerbPatterns,
        [string]$SuccessMessagePrefix,
        [string]$UnavailableMessagePrefix,
        [string]$FailureMessagePrefix
    )

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return [pscustomobject]@{
            MatchedCount     = 0
            SucceededCount   = 0
            UnavailableCount = 0
            FailureCount     = 0
        }
    }

    $shell = $null
    $appsFolder = $null
    $matchedCount = 0
    $succeededCount = 0
    $unavailableCount = 0
    $failureCount = 0

    try {
        $shell = New-Object -ComObject Shell.Application
        $appsFolder = $shell.NameSpace("shell:AppsFolder")
        if ($null -eq $appsFolder) {
            throw 'shell:AppsFolder was unavailable.'
        }

        foreach ($item in @($appsFolder.Items())) {
            foreach ($pattern in $Patterns) {
                if ($item.Name -notlike $pattern) {
                    continue
                }

                $matchedCount++
                try {
                    $verb = Find-ShellVerbByPattern -Item $item -Patterns $VerbPatterns
                    if ($null -ne $verb) {
                        $verb.DoIt()
                        $succeededCount++
                        Write-Log "${SuccessMessagePrefix}: $($item.Name)"
                    } else {
                        $unavailableCount++
                        Write-Log "${UnavailableMessagePrefix}: $($item.Name)" 'WARN'
                    }
                } catch {
                    $failureCount++
                    Write-Log "$FailureMessagePrefix $($item.Name) : $_" 'ERROR'
                }

                break
            }
        }
    } catch {
        $failureCount++
        Write-Log "Failed to process AppsFolder action: $_" 'ERROR'
    } finally {
        if ($null -ne $appsFolder -and [System.Runtime.InteropServices.Marshal]::IsComObject($appsFolder)) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($appsFolder)
        }

        if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    return [pscustomobject]@{
        MatchedCount     = $matchedCount
        SucceededCount   = $succeededCount
        UnavailableCount = $unavailableCount
        FailureCount     = $failureCount
    }
}

function Invoke-AppsFolderUninstallByPatterns {
    param([string[]]$Patterns)
    Invoke-AppsFolderActionByPatterns `
        -Patterns $Patterns `
        -VerbPatterns @('*Uninstall*') `
        -SuccessMessagePrefix 'AppFolder app uninstall invoked' `
        -UnavailableMessagePrefix 'Uninstall verb not available for AppFolder item' `
        -FailureMessagePrefix 'Failed to uninstall AppFolder app'
}

function Invoke-StartMenuUnpinByPatterns {
    param([string[]]$Patterns)
    Invoke-AppsFolderActionByPatterns `
        -Patterns $Patterns `
        -VerbPatterns @('*Unpin*Start*') `
        -SuccessMessagePrefix 'AppFolder app unpinned from Start' `
        -UnavailableMessagePrefix 'Start unpin verb not available for AppFolder item' `
        -FailureMessagePrefix 'Failed to unpin AppFolder app from Start'
}

function Get-DefaultBlockedStartPinsPatterns {
    return @(
        '*LinkedIn*',
        '*LinkedInForWindows*',
        '*linkedin.com*',
        '*LinkedInForWindows_8wekyb3d8bbwe*',
        '*7EE7776C.LinkedInforWindows*',
        '*Xbox*',
        '*Gaming*',
        '*Game Bar*',
        '*xbox.com*',
        '*gamebar*',
        '*ms-gamebar*',
        '*Microsoft.XboxIdentityProvider*',
        '*Microsoft.XboxSpeechToTextOverlay*',
        '*Microsoft.GamingApp*',
        '*Microsoft.Xbox.TCUI*',
        '*Microsoft.XboxGamingOverlay*',
        '*Outlook*',
        '*Microsoft.Outlook*',
        '*Clipchamp*',
        '*News*',
        '*Weather*',
        '*Teams*',
        '*MSTeams*',
        '*MicrosoftTeams*',
        '*To Do*',
        '*Todos*',
        '*Power Automate*',
        '*Sound Recorder*',
        '*Solitaire*',
        '*Candy*',
        '*Bubble Witch*',
        '*Office*',
        '*Microsoft 365*'
    )
}

function Invoke-ApplyLiveStartPinCleanup {
    param([string[]]$BlockedPatterns)

    if ($null -eq $BlockedPatterns -or $BlockedPatterns.Count -eq 0) {
        return (New-TaskSkipResult -Reason 'No blocked Start-pin patterns were provided')
    }

    $cleanupResult = Invoke-StartMenuUnpinByPatterns -Patterns $BlockedPatterns
    if ($null -eq $cleanupResult) {
        return $false
    }

    if ([int]$cleanupResult.FailureCount -gt 0) {
        return $false
    }

    Request-StartSurfaceRestart
    Write-Log ("Applied live Start pin cleanup without staging managed Start pin policy. " +
        "Matched={0}, Unpinned={1}, Unavailable={2}" -f
        [int]$cleanupResult.MatchedCount,
        [int]$cleanupResult.SucceededCount,
        [int]$cleanupResult.UnavailableCount) 'INFO'

    if ([int]$cleanupResult.UnavailableCount -gt 0) {
        return @{
            Success = $true
            Status  = 'CompletedWithWarnings'
            Reason  = 'Some blocked Start items did not expose an unpin verb'
        }
    }

    return $true
}

# ==============================================================================
# HOSTS FILE HELPER
# ==============================================================================

function Add-HostsEntries {
    param([string[]]$Hostnames)
    if ($null -eq $Hostnames -or $Hostnames.Count -eq 0) { return }

    try {
        $hostsFile = $script:HostsFilePath
        $existingContent = @()
        if (Test-Path $hostsFile) {
            $existingContent = @(Get-Content -Path $hostsFile -ErrorAction SilentlyContinue)
        }

        $newEntries = @()
        foreach ($hostname in $Hostnames) {
            $entry = "0.0.0.0 $hostname"
            if ($existingContent -notcontains $entry) {
                $newEntries += $entry
                Write-Log "Hosts entry queued: $entry"
            }
        }

        if ($newEntries.Count -gt 0) {
            Add-Content -Path $hostsFile -Value ($newEntries -join "`n")
            Write-Log "Hosts file updated with $($newEntries.Count) new entries."
        }
    } catch {
        Write-Log "Failed to batch-update hosts file: $_" 'ERROR'
    }
}

# ==============================================================================
# HYPER-V DETECTION
# ==============================================================================

function Test-IsHyperVGuest {
    $probeFailures = New-Object 'System.Collections.Generic.List[string]'

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $cs -and $cs.Model -eq 'Virtual Machine' -and $cs.Manufacturer -eq 'Microsoft Corporation') {
            return $true
        }
    } catch {
        [void]$probeFailures.Add("Win32_ComputerSystem probe failed: $($_.Exception.Message)")
    }

    try {
        # Fallback: check for Hyper-V integration services or VMBUS
        $hyperVService = Get-Service -Name 'vmicheartbeat' -ErrorAction Stop
        if ($null -ne $hyperVService) {
            return $true
        }
    } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
    } catch {
        [void]$probeFailures.Add("vmicheartbeat service probe failed: $($_.Exception.Message)")
    }

    try {
        # Fallback: check for Hyper-V BIOS string
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        if ($null -ne $bios -and $bios.Version -like '*VRTUAL*') {
            return $true
        }
    } catch {
        [void]$probeFailures.Add("Win32_BIOS probe failed: $($_.Exception.Message)")
    }

    if ($probeFailures.Count -gt 0) {
        Write-Log ("Hyper-V guest detection completed with probe warnings: {0}" -f ($probeFailures -join ' | ')) 'WARN'
    }

    return $false
}

function Initialize-HyperVDetection {
    $script:IsHyperVGuest = Test-IsHyperVGuest
    if ($script:IsHyperVGuest) {
        Write-Log "Hyper-V guest detected - autologin will be skipped, RDP services preserved" 'WARN'
    }
}

# ==============================================================================
# CHECKPOINT SYSTEM
# ==============================================================================

function Load-Checkpoint {
    try {
        if (Test-Path $script:CheckpointPath) {
            $checkpointData = Get-Content -Path $script:CheckpointPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $checkpointData -and $checkpointData -is [System.Collections.IEnumerable] -and $checkpointData -isnot [string]) {
                $normalizedCheckpointTasks = New-Object 'System.Collections.Generic.List[string]'
                foreach ($checkpointTaskId in @($checkpointData)) {
                    $taskId = [string]$checkpointTaskId
                    if ([string]::IsNullOrWhiteSpace($taskId)) {
                        continue
                    }

                    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $taskId
                    if (-not $normalizedCheckpointTasks.Contains($resolvedTaskId)) {
                        [void]$normalizedCheckpointTasks.Add($resolvedTaskId)
                    }
                }

                $script:CompletedTasks = @($normalizedCheckpointTasks.ToArray())
                Write-Log "Checkpoint loaded: $($script:CompletedTasks.Count) tasks completed"
                return
            }

            throw 'Checkpoint content was not a JSON task-id array.'
        } else {
            $script:CompletedTasks = @()
            Write-Log "No checkpoint found, starting fresh"
            return
        }
    } catch {
        $script:CompletedTasks = @()
        $script:CheckpointLoadFailed = $true
        Add-RunInfrastructureIssue -Message "Failed to load checkpoint state; starting without resume data: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Save-Checkpoint {
    try {
        Ensure-Directory (Split-Path -Parent $script:CheckpointPath)
        $script:CompletedTasks | ConvertTo-Json -Depth 1 | Set-Content -Path $script:CheckpointPath -Force
        Write-Log "Checkpoint saved: $($script:CompletedTasks.Count) tasks"
    } catch {
        $script:CheckpointSaveFailed = $true
        Add-RunInfrastructureIssue -Message "Failed to persist checkpoint state: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Resolve-TaskCheckpointId {
    param([string]$TaskId)

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return $TaskId
    }

    if ($script:CheckpointAliases.ContainsKey($TaskId)) {
        return $script:CheckpointAliases[$TaskId]
    }

    return $TaskId
}

function Test-TaskCompleted {
    param([string]$TaskId)

    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $TaskId
    return ($script:CompletedTasks -contains $resolvedTaskId)
}

function Add-CompletedTask {
    param([string]$TaskId)

    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $TaskId
    if (-not (Test-TaskCompleted -TaskId $resolvedTaskId)) {
        $script:CompletedTasks = @($script:CompletedTasks) + @($resolvedTaskId)
        Write-Log "Task marked completed: $resolvedTaskId"
    }
}

# ==============================================================================
# PROGRESS WINDOW
# ==============================================================================

function Start-ProgressWindow {
    if ($script:IsAutomationRun) {
        Write-Log 'Automation-safe mode enabled; skipping progress window.' 'INFO'
        return
    }

    try {
        Add-Type -AssemblyName PresentationFramework  -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase            -ErrorAction Stop

        # Synchronized hashtable for cross-thread communication
        $script:UiSync = [hashtable]::Synchronized(@{
            Ready       = $false
            Dispatcher  = $null
            Window      = $null
            TaskData    = $null      # JSON string of task snapshots pushed from main thread
            CloseFlag   = $false
            Error       = $null
        })

        $syncRef = $script:UiSync   # local ref for the scriptblock closure

        # ---------------------------------------------------------------
        # STA Runspace — owns the WPF window and its dispatcher loop
        # ---------------------------------------------------------------
        $script:UiRunspace = [runspacefactory]::CreateRunspace()
        $script:UiRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $script:UiRunspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $script:UiRunspace.Open()
        $script:UiRunspace.SessionStateProxy.SetVariable('Sync', $syncRef)

        $script:UiPipeline = [powershell]::Create()
        $script:UiPipeline.Runspace = $script:UiRunspace
        $script:UiPipeline.AddScript({
            param($Sync)

            Add-Type -AssemblyName PresentationFramework  -ErrorAction Stop
            Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
            Add-Type -AssemblyName WindowsBase            -ErrorAction Stop

            # ---------------------------------------------------------------
            # Helper functions (must live inside the runspace scope)
            # ---------------------------------------------------------------
            function Start-GlassAnimation {
                param(
                    [Parameter(Mandatory)]$Target,
                    [System.Windows.DependencyProperty]$Property,
                    [double]$To,
                    [double]$DurationMs = 350,
                    [switch]$AutoReverse,
                    [switch]$Forever
                )

                if ($null -eq $Target) {
                    throw 'Animation target was null.'
                }

                $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
                $anim.To = $To
                $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($DurationMs))
                $anim.EasingFunction = [System.Windows.Media.Animation.CubicEase]@{ EasingMode = 'EaseOut' }
                if ($AutoReverse) { $anim.AutoReverse = $true }
                if ($Forever) { $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
                $Target.BeginAnimation($Property, $anim)
            }

            function Start-GlassColorAnimation {
                param(
                    [System.Windows.Media.SolidColorBrush]$Brush,
                    [string]$ToColor,
                    [double]$DurationMs = 400
                )
                $anim = [System.Windows.Media.Animation.ColorAnimation]::new()
                $anim.To = [System.Windows.Media.ColorConverter]::ConvertFromString($ToColor)
                $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($DurationMs))
                $anim.EasingFunction = [System.Windows.Media.Animation.CubicEase]@{ EasingMode = 'EaseOut' }
                $Brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
            }

            # ---------------------------------------------------------------
            # XAML — liquid glass overlay
            # ---------------------------------------------------------------
            [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hunter" Height="520" Width="340"
        WindowStartupLocation="Manual"
        ResizeMode="CanResizeWithGrip"
        AllowsTransparency="True" WindowStyle="None"
        Background="Transparent" Topmost="True"
        ShowInTaskbar="True">
    <Grid>
        <Border CornerRadius="16" x:Name="GlassShell">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#D8101828" Offset="0.0"/>
                    <GradientStop Color="#E0141E30" Offset="0.4"/>
                    <GradientStop Color="#D0101828" Offset="1.0"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.BorderBrush>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#50FFFFFF" Offset="0.0"/>
                    <GradientStop Color="#15FFFFFF" Offset="0.5"/>
                    <GradientStop Color="#30FFFFFF" Offset="1.0"/>
                </LinearGradientBrush>
            </Border.BorderBrush>
            <Border.BorderThickness>1</Border.BorderThickness>
            <Border.Effect>
                <DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="0" Opacity="0.5"/>
            </Border.Effect>
            <Grid>
                <Border CornerRadius="16" IsHitTestVisible="False" VerticalAlignment="Top" Height="80">
                    <Border.Background>
                        <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
                            <GradientStop Color="#18FFFFFF" Offset="0.0"/>
                            <GradientStop Color="#00FFFFFF" Offset="1.0"/>
                        </LinearGradientBrush>
                    </Border.Background>
                </Border>
                <Border CornerRadius="16" IsHitTestVisible="False" VerticalAlignment="Bottom"
                        HorizontalAlignment="Right" Width="120" Height="120" Margin="0,0,8,8">
                    <Border.Background>
                        <RadialGradientBrush>
                            <GradientStop Color="#103B82F6" Offset="0.0"/>
                            <GradientStop Color="#00000000" Offset="1.0"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Grid Margin="18">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                        <TextBlock Text="HUNTER" FontSize="14" FontWeight="Bold" Foreground="#60A5FA"
                                   FontFamily="Segoe UI" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TitleStatus" Text="  Initializing..." FontSize="11"
                                   Foreground="#9CA3AF" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                    </StackPanel>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Disabled" Margin="0,0,0,10">
                        <StackPanel x:Name="PhasePanel" />
                    </ScrollViewer>
                    <Grid Grid.Row="2" Margin="0,4,0,2" Height="10">
                        <Border CornerRadius="5" Background="#0D1117">
                            <Border.BorderBrush>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                    <GradientStop Color="#20000000" Offset="0"/>
                                    <GradientStop Color="#10FFFFFF" Offset="1"/>
                                </LinearGradientBrush>
                            </Border.BorderBrush>
                            <Border.BorderThickness>1</Border.BorderThickness>
                        </Border>
                        <Border x:Name="ProgressFill" CornerRadius="5"
                                HorizontalAlignment="Left" Width="0" Height="10" ClipToBounds="True">
                            <Border.Background>
                                <LinearGradientBrush x:Name="ShimmerBrush" StartPoint="0,0" EndPoint="1,0"
                                                     SpreadMethod="Reflect">
                                    <GradientStop Color="#3B82F6" Offset="0.0"/>
                                    <GradientStop Color="#60A5FA" Offset="0.3"/>
                                    <GradientStop Color="#93C5FD" Offset="0.5"/>
                                    <GradientStop Color="#60A5FA" Offset="0.7"/>
                                    <GradientStop Color="#3B82F6" Offset="1.0"/>
                                </LinearGradientBrush>
                            </Border.Background>
                            <Border CornerRadius="5" VerticalAlignment="Top" Height="5" Margin="1,1,1,0"
                                    IsHitTestVisible="False">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
                                        <GradientStop Color="#40FFFFFF" Offset="0.0"/>
                                        <GradientStop Color="#00FFFFFF" Offset="1.0"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                            </Border>
                        </Border>
                    </Grid>
                    <TextBlock Grid.Row="3" x:Name="ProgressText" Text="0 / 0 tasks"
                               FontSize="10" Foreground="#6B7280" FontFamily="Segoe UI"
                               HorizontalAlignment="Center" Margin="0,4,0,0"/>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

            $reader = [System.Xml.XmlNodeReader]::new($xaml)
            $window = [System.Windows.Markup.XamlReader]::Load($reader)

            # Position at top-right of primary screen
            $screen = [System.Windows.SystemParameters]::WorkArea
            $window.Left = $screen.Right - 360
            $window.Top  = $screen.Top + 16

            # Draggable
            $window.Add_MouseLeftButtonDown({ $this.DragMove() })

            # Named elements
            $phasePanel  = $window.FindName('PhasePanel')
            $progressFill = $window.FindName('ProgressFill')
            $progressText = $window.FindName('ProgressText')
            $titleStatus  = $window.FindName('TitleStatus')
            $shimmerBrush = $window.FindName('ShimmerBrush')

            # Shimmer animation
            $shimmerTransform = [System.Windows.Media.TranslateTransform]::new()
            $shimmerBrush.RelativeTransform = $shimmerTransform
            $shimmerAnim = [System.Windows.Media.Animation.DoubleAnimation]::new()
            $shimmerAnim.From = 0.0
            $shimmerAnim.To = 1.0
            $shimmerAnim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(2))
            $shimmerAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $shimmerAnim.AutoReverse = $true
            $shimmerTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $shimmerAnim)

            # Phase metadata
            $phaseLabels = [ordered]@{
                '1' = 'Preflight'; '2' = 'Core Setup'; '3' = 'Start / UI'; '4' = 'Explorer'
                '5' = 'Microsoft Cloud'; '6' = 'Remove Apps'; '7' = 'System Tweaks'
                '8' = 'External Tools'; '9' = 'Cleanup'
            }

            $phaseCircles    = @{}
            $phaseLabelsUI   = @{}
            $phaseTaskPanels = @{}
            $phaseGlowBorders = @{}
            $prevPhaseStatuses = @{}

            foreach ($phaseNum in @('1','2','3','4','5','6','7','8','9')) {
                $prevPhaseStatuses[$phaseNum] = 'Pending'
                $phaseInfo = $phaseLabels[$phaseNum]

                $row = [System.Windows.Controls.StackPanel]::new()
                $row.Orientation = 'Horizontal'
                $row.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)

                $glowGrid = [System.Windows.Controls.Grid]::new()
                $glowGrid.Width = 30; $glowGrid.Height = 30
                $glowGrid.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
                $glowGrid.VerticalAlignment = 'Top'

                $glowBorder = [System.Windows.Controls.Border]::new()
                $glowBorder.CornerRadius = [System.Windows.CornerRadius]::new(15)
                $glowBorder.Width = 30; $glowBorder.Height = 30
                $glowBorder.Background = [System.Windows.Media.Brushes]::Transparent
                $glowBorder.Opacity = 0
                $glowBorder.IsHitTestVisible = $false

                $circleBorder = [System.Windows.Controls.Border]::new()
                $circleBorder.CornerRadius = [System.Windows.CornerRadius]::new(14)
                $circleBorder.Width = 28; $circleBorder.Height = 28
                $circleBorder.HorizontalAlignment = 'Center'
                $circleBorder.VerticalAlignment = 'Center'
                $circleBorder.BorderThickness = [System.Windows.Thickness]::new(2)
                $circleBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#3B4555'))
                $circleBorder.Background = [System.Windows.Media.Brushes]::Transparent
                $circleBorder.Effect = [System.Windows.Media.Effects.DropShadowEffect]@{
                    Color = '#000000'; BlurRadius = 4; ShadowDepth = 0; Opacity = 0.3; Direction = 270
                }

                $circleText = [System.Windows.Controls.TextBlock]::new()
                $circleText.Text = $phaseNum
                $circleText.FontSize = 12
                $circleText.FontWeight = 'SemiBold'
                $circleText.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
                $circleText.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                $circleText.HorizontalAlignment = 'Center'
                $circleText.VerticalAlignment = 'Center'

                $scaleTransform = [System.Windows.Media.ScaleTransform]::new(1.0, 1.0)
                $scaleTransform.CenterX = 14; $scaleTransform.CenterY = 14
                $circleBorder.RenderTransform = $scaleTransform

                $glowGrid.Children.Add($glowBorder) | Out-Null
                $glowGrid.Children.Add($circleBorder) | Out-Null
                $glowGrid.Children.Add($circleText) | Out-Null

                $lbl = [System.Windows.Controls.TextBlock]::new()
                $lbl.Text = $phaseInfo
                $lbl.FontSize = 13
                $lbl.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
                $lbl.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#9CA3AF'))
                $lbl.VerticalAlignment = 'Top'
                $lbl.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)

                $row.Children.Add($glowGrid) | Out-Null
                $row.Children.Add($lbl) | Out-Null

                $taskPanel = [System.Windows.Controls.StackPanel]::new()
                $taskPanel.Margin = [System.Windows.Thickness]::new(40, 2, 0, 4)
                $taskPanel.Opacity = 0; $taskPanel.MaxHeight = 0

                $wrapper = [System.Windows.Controls.StackPanel]::new()
                $wrapper.Children.Add($row) | Out-Null
                $wrapper.Children.Add($taskPanel) | Out-Null
                $phasePanel.Children.Add($wrapper) | Out-Null

                $phaseCircles[$phaseNum] = @{
                    Grid = $glowGrid; Border = $circleBorder; Text = $circleText; Scale = $scaleTransform
                }
                $phaseLabelsUI[$phaseNum]    = $lbl
                $phaseTaskPanels[$phaseNum]  = $taskPanel
                $phaseGlowBorders[$phaseNum] = $glowBorder
            }

            # ---------------------------------------------------------------
            # Refresh function — called via dispatcher on this STA thread
            # ---------------------------------------------------------------
            $refreshAction = {
                try {
                    $json = $Sync.TaskData
                    if ($null -eq $json) { return }

                    $Tasks = $json | ConvertFrom-Json

                    $checkMark = [char]0x2713

                    $phaseStatuses = @{}
                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $phaseStatuses[$pn] = 'Pending'
                    }

                    $totalTasks = 0; $doneTasks = 0; $failCount = 0; $runningTaskDesc = $null

                    foreach ($t in $Tasks) {
                        if ($null -eq $t) { continue }
                        $totalTasks++
                        $p = [string]$t.Phase
                        switch ($t.Status) {
                            'Running'              { $phaseStatuses[$p] = 'Running'; $runningTaskDesc = $t.Description }
                            'Completed'            { $doneTasks++ }
                            'CompletedWithWarnings' { $doneTasks++ }
                            'Skipped'              { $doneTasks++ }
                            'Failed'               { $doneTasks++; $failCount++ }
                        }
                    }

                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $pTasks = @($Tasks | Where-Object { $null -ne $_ -and [string]$_.Phase -eq $pn })
                        if ($pTasks.Count -eq 0) { continue }
                        $allDone = $true; $hasRunning = $false; $hasFailed = $false
                        foreach ($pt in $pTasks) {
                            if ($pt.Status -eq 'Running')  { $hasRunning = $true; $allDone = $false }
                            elseif ($pt.Status -eq 'Pending') { $allDone = $false }
                            elseif ($pt.Status -eq 'Failed')  { $hasFailed = $true }
                        }
                        if ($hasRunning)              { $phaseStatuses[$pn] = 'Running' }
                        elseif ($allDone -and $hasFailed) { $phaseStatuses[$pn] = 'Failed' }
                        elseif ($allDone)             { $phaseStatuses[$pn] = 'Completed' }
                    }

                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $circle = $phaseCircles[$pn]
                        $label  = $phaseLabelsUI[$pn]
                        $tPanel = $phaseTaskPanels[$pn]
                        $glow   = $phaseGlowBorders[$pn]
                        $status = $phaseStatuses[$pn]
                        $prev   = $prevPhaseStatuses[$pn]
                        $isTransition = ($status -ne $prev)

                        switch ($status) {
                            'Completed' {
                                if ($isTransition) {
                                    $glow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                                    $glow.Opacity = 0

                                    $fillBrush = [System.Windows.Media.LinearGradientBrush]::new()
                                    $fillBrush.StartPoint = [System.Windows.Point]::new(0.3, 0)
                                    $fillBrush.EndPoint   = [System.Windows.Point]::new(0.7, 1)
                                    $fillBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'), 0.0))
                                    $fillBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'), 0.5))
                                    $fillBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#2563EB'), 1.0))
                                    $circle.Border.Background = $fillBrush
                                    $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))

                                    $popUp = [System.Windows.Media.Animation.DoubleAnimation]::new()
                                    $popUp.To = 1.25
                                    $popUp.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
                                    $popUp.AutoReverse = $true
                                    $popUp.EasingFunction = [System.Windows.Media.Animation.CubicEase]@{ EasingMode = 'EaseOut' }
                                    $circle.Scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $popUp)
                                    $circle.Scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $popUp)

                                    Start-GlassAnimation -Target $tPanel -Property ([System.Windows.UIElement]::OpacityProperty) -To 0 -DurationMs 200
                                    Start-GlassAnimation -Target $tPanel -Property ([System.Windows.FrameworkElement]::MaxHeightProperty) -To 0 -DurationMs 300
                                }

                                $circle.Text.Text = [string]$checkMark
                                $circle.Text.FontSize = 14
                                $circle.Text.Foreground = [System.Windows.Media.Brushes]::White

                                if ($label.Foreground -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#4B5563'))
                                } else {
                                    Start-GlassColorAnimation -Brush $label.Foreground -ToColor '#4B5563' -DurationMs 400
                                }
                                $label.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                            }

                            'Running' {
                                $circle.Border.Background = [System.Windows.Media.Brushes]::Transparent

                                if ($circle.Border.BorderBrush -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'))
                                } else {
                                    Start-GlassColorAnimation -Brush $circle.Border.BorderBrush -ToColor '#3B82F6' -DurationMs 300
                                }

                                $circle.Text.Text = $pn
                                $circle.Text.FontSize = 12
                                if ($circle.Text.Foreground -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $circle.Text.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))
                                } else {
                                    Start-GlassColorAnimation -Brush $circle.Text.Foreground -ToColor '#60A5FA' -DurationMs 300
                                }

                                if ($label.Foreground -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))
                                } else {
                                    Start-GlassColorAnimation -Brush $label.Foreground -ToColor '#60A5FA' -DurationMs 300
                                }
                                $label.TextDecorations = $null

                                if ($isTransition) {
                                    $glow.Background = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'))
                                    Start-GlassAnimation -Target $glow -Property ([System.Windows.UIElement]::OpacityProperty) `
                                        -To 0.4 -DurationMs 800 -AutoReverse -Forever
                                }

                                Start-GlassAnimation -Target $tPanel -Property ([System.Windows.UIElement]::OpacityProperty) -To 1.0 -DurationMs 250
                                Start-GlassAnimation -Target $tPanel -Property ([System.Windows.FrameworkElement]::MaxHeightProperty) -To 500 -DurationMs 350

                                $tPanel.Children.Clear()
                                $phaseTasks = @($Tasks | Where-Object { $null -ne $_ -and [string]$_.Phase -eq $pn })
                                foreach ($pt in $phaseTasks) {
                                    $tb = [System.Windows.Controls.TextBlock]::new()
                                    $tb.FontSize   = 11
                                    $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
                                    $tb.Margin     = [System.Windows.Thickness]::new(0, 1, 0, 1)
                                    switch ($pt.Status) {
                                        'Completed' {
                                            $tb.Text = "  $($checkMark)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#4B5563'))
                                            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                                        }
                                        'CompletedWithWarnings' {
                                            $tb.Text = "  $($checkMark)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#F59E0B'))
                                            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                                        }
                                        'Running' {
                                            $tb.Text = "  $([char]0x25B6)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))
                                        }
                                        'Failed' {
                                            $tb.Text = "  $([char]0x2717)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#EF4444'))
                                        }
                                        'Skipped' {
                                            $tb.Text = "  -  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#4B5563'))
                                            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                                        }
                                        default {
                                            $tb.Text = "  $([char]0x25CB)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                                        }
                                    }
                                    $tPanel.Children.Add($tb) | Out-Null
                                }
                            }

                            'Failed' {
                                if ($isTransition) {
                                    $glow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                                    $glow.Opacity = 0
                                }
                                $failGrad = [System.Windows.Media.LinearGradientBrush]::new()
                                $failGrad.StartPoint = [System.Windows.Point]::new(0.3, 0)
                                $failGrad.EndPoint   = [System.Windows.Point]::new(0.7, 1)
                                $failGrad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#F87171'), 0.0))
                                $failGrad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#EF4444'), 0.5))
                                $failGrad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#DC2626'), 1.0))
                                $circle.Border.Background = $failGrad
                                $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#F87171'))
                                $circle.Text.Text = [char]0x2717
                                $circle.Text.FontSize = 13
                                $circle.Text.Foreground = [System.Windows.Media.Brushes]::White
                                $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#EF4444'))
                                $label.TextDecorations = $null

                                Start-GlassAnimation -Target $tPanel -Property ([System.Windows.UIElement]::OpacityProperty) -To 0 -DurationMs 200
                                Start-GlassAnimation -Target $tPanel -Property ([System.Windows.FrameworkElement]::MaxHeightProperty) -To 0 -DurationMs 300
                            }

                            default {
                                $circle.Border.Background = [System.Windows.Media.Brushes]::Transparent
                                $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#3B4555'))
                                $circle.Text.Text = $pn
                                $circle.Text.FontSize = 12
                                $circle.Text.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                                $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                                $label.TextDecorations = $null
                                $tPanel.MaxHeight = 0
                                $tPanel.Opacity = 0
                            }
                        }
                    }

                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $prevPhaseStatuses[$pn] = $phaseStatuses[$pn]
                    }

                    if ($totalTasks -gt 0) {
                        $pct = [Math]::Round(($doneTasks / $totalTasks) * 100, 0)
                        $barMaxWidth = $progressFill.Parent.ActualWidth
                        if ($barMaxWidth -le 0) { $barMaxWidth = 300 }
                        $targetWidth = [Math]::Max(0, ($barMaxWidth * $doneTasks / $totalTasks))
                        Start-GlassAnimation -Target $progressFill `
                            -Property ([System.Windows.FrameworkElement]::WidthProperty) `
                            -To $targetWidth -DurationMs 500
                        $progressText.Text = "$doneTasks / $totalTasks tasks  ($pct%)"
                    }

                    if ($null -ne $runningTaskDesc) {
                        $titleStatus.Text = "  $runningTaskDesc"
                    } elseif ($doneTasks -eq $totalTasks -and $totalTasks -gt 0) {
                        $titleStatus.Text = '  Complete!'
                    }

                    $Sync.Error = $null
                } catch {
                    $Sync.Error = $_.Exception.Message
                }
            }

            # ---------------------------------------------------------------
            # DispatcherTimer — polls synchronized hashtable for updates
            # ---------------------------------------------------------------
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(250)
            $timer.Add_Tick({
                # Check for close request
                if ($Sync.CloseFlag) {
                    $window.Close()
                    return
                }
                # Check for data update
                if ($null -ne $Sync.TaskData) {
                    & $refreshAction
                }
            }.GetNewClosure())
            $timer.Start()

            # Signal readiness to main thread
            $Sync.Dispatcher = $window.Dispatcher
            $Sync.Window     = $window
            $Sync.Ready      = $true

            # Show window and start message pump
            $window.Show()
            [System.Windows.Threading.Dispatcher]::Run()

        }).AddArgument($syncRef) | Out-Null

        # Launch the UI runspace asynchronously
        $script:UiAsyncResult = $script:UiPipeline.BeginInvoke()

        # Wait for the UI thread to signal readiness (up to 10 seconds)
        $waitStart = [DateTime]::UtcNow
        while (-not $script:UiSync.Ready) {
            Start-Sleep -Milliseconds 50
            if (([DateTime]::UtcNow - $waitStart).TotalSeconds -gt 10) {
                if ($null -ne $script:UiPipeline -and $script:UiPipeline.Streams.Error.Count -gt 0) {
                    $uiError = $script:UiPipeline.Streams.Error[0]
                    Write-Log "Progress UI thread did not signal ready within 10s: $uiError" 'WARN'
                } else {
                    Write-Log 'Progress UI thread did not signal ready within 10s' 'WARN'
                }
                break
            }
        }

        if ($script:UiSync.Ready) {
            Write-Log 'Progress overlay started (liquid glass, STA runspace)' 'INFO'
        }
    } catch {
        Write-Log "Failed to start progress overlay: $_" 'WARN'
    }
}

function Close-ProgressWindow {
    if ($null -ne $script:UiSync) {
        try {
            $script:UiSync.CloseFlag = $true

            # Give the dispatcher timer a moment to process the close
            $waitStart = [DateTime]::UtcNow
            while ($null -ne $script:UiSync.Window -and
                   ([DateTime]::UtcNow - $waitStart).TotalSeconds -lt 3) {
                Start-Sleep -Milliseconds 100
            }

            # Force-shutdown the dispatcher if still alive
            if ($null -ne $script:UiSync.Dispatcher) {
                try {
                    $script:UiSync.Dispatcher.BeginInvokeShutdown(
                        [System.Windows.Threading.DispatcherPriority]::Send)
                } catch { }
            }
        } catch { }

        # Cleanup runspace
        try {
            if ($null -ne $script:UiPipeline) {
                $script:UiPipeline.Stop()
                $script:UiPipeline.Dispose()
            }
        } catch { }
        try {
            if ($null -ne $script:UiRunspace) {
                $script:UiRunspace.Close()
                $script:UiRunspace.Dispose()
            }
        } catch { }

        $script:UiSync     = $null
        $script:UiPipeline = $null
        $script:UiRunspace = $null
        $script:UiAsyncResult = $null
    }
}

function Update-ProgressUI {
    <#
    .SYNOPSIS
    Pushes task state to the UI runspace via the synchronized hashtable.
    The UI thread's DispatcherTimer picks up the data and renders it asynchronously.
    This call is non-blocking — the main thread never waits for the UI to render.
    #>
    param([object[]]$Tasks)

    if ($null -eq $script:UiSync -or -not $script:UiSync.Ready) { return }

    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$script:UiSync.Error) -and -not $script:ProgressUiIssueLogged) {
            $script:ProgressUiIssueLogged = $true
            Add-RunInfrastructureIssue -Message "Progress overlay refresh failed; task execution continued without a reliable live UI: $($script:UiSync.Error)" -Level 'WARN'
        }

        # Serialize task state to JSON — the UI thread deserializes independently
        $snapshot = @()
        foreach ($task in @($Tasks)) {
            if ($null -eq $task) { continue }
            $snapshot += [ordered]@{
                TaskId      = [string]$task.TaskId
                Phase       = [string]$task.Phase
                Description = [string]$task.Description
                Status      = [string]$task.Status
                Error       = if ($null -ne $task.Error) { [string]$task.Error } else { $null }
            }
        }
        $script:UiSync.TaskData = ($snapshot | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        if (-not $script:ProgressUiIssueLogged) {
            $script:ProgressUiIssueLogged = $true
            Add-RunInfrastructureIssue -Message "Progress overlay updates failed; task execution continued without reliable UI refreshes: $($_.Exception.Message)" -Level 'WARN'
        }
    }
}

function Update-ProgressState {
    param([object[]]$Tasks)
    Update-ProgressUI -Tasks $Tasks
}

# ==============================================================================
# EXPLORER RESTART
# ==============================================================================

function Request-ExplorerRestart {
    if ($script:ExplorerRestartPending) {
        return
    }

    $script:ExplorerRestartPending = $true
    Write-Log "Explorer restart queued (will apply at end of run)"
}

function Request-StartSurfaceRestart {
    if ($script:StartSurfaceRestartPending) {
        return
    }

    $script:StartSurfaceRestartPending = $true
    Write-Log "Start surface restart queued (will apply at end of run)"
}

function Invoke-DeferredExplorerRestart {
    try {
        $reconcileSucceeded = $true
        if ($script:TaskbarReconcilePending) {
            $reconcileSucceeded = Invoke-ReconcileTaskbarPins
        }

        if ($script:ExplorerRestartPending) {
            Write-Log "Restarting Explorer..."
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $null = Start-Process explorer.exe -ErrorAction Stop
            $script:ExplorerRestartPending = $false
            $script:StartSurfaceRestartPending = $false
            Write-Log "Explorer restarted"
            return $reconcileSucceeded
        }

        if ($script:StartSurfaceRestartPending) {
            return ((Restart-StartSurface) -and $reconcileSucceeded)
        }

        return $reconcileSucceeded
    } catch {
        Write-Log "Failed to apply deferred Explorer restart actions: $_" 'ERROR'
        return $false
    }
}

function Restart-StartSurface {
    try {
        Get-Process -Name 'StartMenuExperienceHost', 'ShellExperienceHost' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $script:StartSurfaceRestartPending = $false
        Write-Log "Start surface restarted"
        return $true
    } catch {
        Write-Log "Failed to restart Start surface : $_" 'ERROR'
        return $false
    }
}

function Invoke-ReconcileTaskbarPins {
    try {
        Write-Log 'Reconciling taskbar pins...' 'INFO'

        $taskbarPinPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"

        if (-not (Restart-StartSurface)) {
            throw 'Failed to restart the Start surface before deferred taskbar reconciliation.'
        }
        $null = Invoke-RemoveDefaultTaskbarSurfaceArtifacts

        # Ensure shortcuts exist for all apps that need pinning (required for both
        # the direct placement approach and the Group Policy XML layout).
        Ensure-Directory $taskbarPinPath
        $preparedPinnedApps = Get-PreparedTaskbarPinnedApps -LogMissingExecutable $true
        foreach ($preparedPin in @($preparedPinnedApps)) {
            $pinSpec = $preparedPin.PinSpec
            # Place .lnk in the Quick Launch pin folder (works on Win10, best-effort on Win11)
            $pinLnkPath = Join-Path $taskbarPinPath "$($pinSpec.ShortcutName).lnk"
            if (-not (Test-Path $pinLnkPath)) {
                if (-not (New-WindowsShortcut -ShortcutPath $pinLnkPath -TargetPath $preparedPin.ExecutablePath -Description $pinSpec.PackageName)) {
                    throw "Failed to prepare taskbar shortcut for $($pinSpec.PackageName)."
                }
            }
        }

        # Clear Explorer Taskband cache so it rebuilds from pin folder on restart (Win10).
        try {
            $taskbandPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
            if (Test-Path $taskbandPath) {
                Remove-Item -Path $taskbandPath -Recurse -Force -ErrorAction Stop
                Write-Log 'Cleared Explorer Taskband cache.' 'INFO'
            }
        } catch {
            Write-Log "Failed to clear Taskband cache: $_" 'WARN'
        }

        # Register a logon script that retries pinning via shell verbs at fresh logon.
        # At fresh logon the shell:AppsFolder is properly initialized and pin verbs are
        # available on Win10 and some Win11 builds where they fail mid-session.
        if (-not (Register-TaskbarPinAtLogonTask)) {
            throw 'Failed to register the deferred taskbar pin retry task.'
        }

        $script:TaskbarReconcilePending = $false
        return $true
    } catch {
        Write-Log "Failed to reconcile taskbar pins : $_" 'ERROR'
        return $false
    }
}

function Register-TaskbarPinAtLogonTask {
    try {
        $taskName = 'Hunter-TaskbarPinAtLogon'
        $scriptPath = Join-Path $script:HunterRoot 'TaskbarPinAtLogon.ps1'
        $logPath = Join-Path $script:HunterRoot 'taskbar-pin-at-logon.log'

        # Build the pin spec list as literal PowerShell that the logon script can use.
        $pinSpecLines = @()
        foreach ($pinSpec in @(Get-TaskbarPinnedInstallTargets)) {
            $executablePath = & $pinSpec.GetExecutable
            if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path $executablePath)) {
                continue
            }
            $escapedName = ($pinSpec.ShortcutName -replace "'", "''")
            $escapedPatterns = ($pinSpec.PinPatterns | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ', '
            $pinSpecLines += "    @{ Name = '$escapedName'; Patterns = @($escapedPatterns) }"
        }
        $pinSpecArray = $pinSpecLines -join "`n"

        $logonScript = @"
        `$ErrorActionPreference = 'Stop'
        `$logPath = '$($logPath -replace "'","''")'

        function Write-RetryLog {
            param(
                [string]`$Message,
                [string]`$Level = 'INFO'
            )

            `$line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Level, `$Message
            try {
                Add-Content -Path `$logPath -Value `$line -ErrorAction Stop
            } catch {
            }
        }

        `$hadFailure = `$false

# Wait for Explorer shell to fully initialise after logon.
Start-Sleep -Seconds 12

`$pinVerbPatterns = @('*Pin to taskbar*', '*taskbarpin*')
`$unpinVerbPatterns = @('*Unpin from taskbar*', '*taskbarunpin*')
`$appsToPin = @(
$pinSpecArray
)
`$appsToUnpin = @('*Edge*', '*Microsoft Edge*', '*Microsoft Store*')

try {
    `$shell = New-Object -ComObject Shell.Application
    `$appsFolder = `$shell.NameSpace('shell:AppsFolder')
    if (`$null -eq `$appsFolder) {
        throw 'shell:AppsFolder was unavailable at logon.'
    }
} catch {
    Write-RetryLog -Message "Failed to initialize shell: $($_.Exception.Message)" -Level 'ERROR'
    exit 1
}

# Unpin Edge and Store
foreach (`$item in `$appsFolder.Items()) {
    foreach (`$pattern in `$appsToUnpin) {
        if (`$item.Name -like `$pattern) {
            foreach (`$verb in `$item.Verbs()) {
                foreach (`$vp in `$unpinVerbPatterns) {
                    if (`$verb.Name -like `$vp) {
                        try {
                            `$verb.DoIt()
                        } catch {
                            `$hadFailure = `$true
                            Write-RetryLog -Message "Failed to unpin $(`$item.Name): $($_.Exception.Message)" -Level 'WARN'
                        }
                        break
                    }
                }
            }
        }
    }
}

# Pin desired apps
foreach (`$app in `$appsToPin) {
    `$pinned = `$false
    foreach (`$item in `$appsFolder.Items()) {
        if (`$pinned) { break }
        foreach (`$pattern in `$app.Patterns) {
            if (`$item.Name -like `$pattern) {
                foreach (`$verb in `$item.Verbs()) {
                    foreach (`$vp in `$pinVerbPatterns) {
                        if (`$verb.Name -like `$vp) {
                            try {
                                `$verb.DoIt()
                                `$pinned = `$true
                            } catch {
                                `$hadFailure = `$true
                                Write-RetryLog -Message "Failed to pin $(`$item.Name): $($_.Exception.Message)" -Level 'WARN'
                            }
                            break
                        }
                    }
                    if (`$pinned) { break }
                }
            }
            if (`$pinned) { break }
        }
    }

    if (-not `$pinned) {
        `$hadFailure = `$true
        Write-RetryLog -Message "No pin verb succeeded for $(`$app.Name)." -Level 'WARN'
    }
}

if (`$null -ne `$appsFolder -and [System.Runtime.InteropServices.Marshal]::IsComObject(`$appsFolder)) {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject(`$appsFolder)
}
if (`$null -ne `$shell -and [System.Runtime.InteropServices.Marshal]::IsComObject(`$shell)) {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject(`$shell)
}

# Self-cleanup
try {
    Unregister-ScheduledTask -TaskName '$($taskName -replace "'","''")' -Confirm:`$false -ErrorAction Stop
} catch {
    Write-RetryLog -Message "Failed to unregister retry task during self-cleanup: $($_.Exception.Message)" -Level 'WARN'
}
try {
    Remove-Item -LiteralPath '$($scriptPath -replace "'","''")' -Force -ErrorAction Stop
} catch {
    Write-RetryLog -Message "Failed to delete retry script during self-cleanup: $($_.Exception.Message)" -Level 'WARN'
}

if (`$hadFailure) {
    exit 1
}
"@

        Ensure-Directory (Split-Path -Parent $scriptPath)
        Set-Content -Path $scriptPath -Value $logonScript -Encoding UTF8 -Force

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Force | Out-Null

        Write-Log "Registered logon task '$taskName' to retry taskbar pinning via shell verbs at next logon." 'INFO'
        return $true
    } catch {
        Write-Log "Failed to register taskbar pin logon task: $_" 'ERROR'
        return $false
    }
}

function Get-ExplorerNamespaceRoots {
    $roots = @()
    $desktopRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop'
    )

    foreach ($desktopRoot in $desktopRoots) {
        if (Test-Path $desktopRoot) {
            foreach ($child in @(Get-ChildItem -Path $desktopRoot -ErrorAction SilentlyContinue)) {
                if ($child.PSChildName -like 'NameSpace*') {
                    $roots += $child.PSPath
                }
            }
        }

        $roots += "$desktopRoot\NameSpace"
    }

    return $roots | Select-Object -Unique
}

function Test-ExplorerNamespacePresent {
    param([string]$Guid)

    foreach ($root in @(Get-ExplorerNamespaceRoots)) {
        if (Test-Path "$root\$Guid") {
            return $true
        }
    }

    return $false
}

function Remove-ExplorerNamespaceGuid {
    param([string]$Guid)

    foreach ($root in @(Get-ExplorerNamespaceRoots)) {
        Remove-RegistryKey -Path "$root\$Guid"
    }
}

function Remove-ExplorerNamespaceAndVerify {
    param(
        [string]$Guid,
        [string]$DisplayName
    )

    Remove-ExplorerNamespaceGuid -Guid $Guid
    Set-ExplorerNamespacePinnedState -Guid $Guid -Value 0

    if (Test-ExplorerNamespacePresent -Guid $Guid) {
        throw "Explorer $DisplayName namespace is still present: $Guid"
    }
}

function Set-ExplorerNamespacePinnedState {
    param(
        [string]$Guid,
        [int]$Value = 0
    )

    $userOverridePath = "Software\Classes\CLSID\$Guid"
    $machineOverridePath = "HKLM:\SOFTWARE\Classes\CLSID\$Guid"

    Set-DwordForAllUsers -SubPath $userOverridePath -Name 'System.IsPinnedToNameSpaceTree' -Value $Value

    try {
        $parentPath = Split-Path -Parent $machineOverridePath
        $leaf = Split-Path -Leaf $machineOverridePath

        if (-not (Test-Path $machineOverridePath) -and (Test-Path $parentPath)) {
            New-Item -Path $parentPath -Name $leaf -Force | Out-Null
        }

        if (Test-Path $machineOverridePath) {
            Set-ItemProperty -Path $machineOverridePath -Name 'System.IsPinnedToNameSpaceTree' -Value $Value -Type DWord -Force
            Write-Log "Registry set: $machineOverridePath\System.IsPinnedToNameSpaceTree = $Value (DWord)"
        }
    } catch {
        Write-Log "Machine-wide namespace pin override skipped for ${Guid}: $_" 'WARN'
    }
}

# ==============================================================================
# PHASE 1 - PREFLIGHT
# ==============================================================================

function Invoke-CreateRestorePoint {
    if (Test-TaskCompleted -TaskId 'preflight-restore-point') {
        Write-Log "Restore point already created, skipping"
        return (New-TaskSkipResult -Reason 'Restore point already exists in the checkpoint state')
    }

    if ($script:IsAutomationRun) {
        Write-Log 'Automation-safe mode enabled; skipping restore point creation.' 'WARN'
        return (New-TaskSkipResult -Reason 'Restore point creation skipped in automation-safe mode')
    }

    $shouldCreateRestorePoint = Show-YesNoDialog `
        -Title 'Hunter Restore Point' `
        -Message "Create a Windows System Restore point before Hunter continues?`n`nThis can take several minutes and may stall on some systems.`n`nChoose Yes to create one now, or No to skip this step." `
        -DefaultToNo $true

    if (-not $shouldCreateRestorePoint) {
        Write-Log 'Restore point creation skipped by user.' 'WARN'
        return (New-TaskSkipResult -Reason 'Restore point creation was skipped by the user')
    }

    $restorePointJob = $null
    $restorePointTimeoutSeconds = 300
    $systemRestorePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $originalFrequencyExists = $false
    $originalFrequencyValue = $null

    try {
        if (Test-Path $systemRestorePath) {
            try {
                $existingFrequency = Get-ItemProperty -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop
                $originalFrequencyValue = [int]$existingFrequency.SystemRestorePointCreationFrequency
                $originalFrequencyExists = $true
            } catch [System.Management.Automation.ItemNotFoundException] {
            }
        }

        Set-RegistryValue -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type 'DWord'
        if (-not (Test-RegistryValue -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -ExpectedValue 0)) {
            throw 'SystemRestorePointCreationFrequency was not persisted.'
        }

        $restorePointJob = Start-Job -ScriptBlock {
            param($Drive)

            $ErrorActionPreference = 'Stop'
            Enable-ComputerRestore -Drive $Drive -ErrorAction Stop
            Checkpoint-Computer -Description 'Hunter Pre-Install' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop

            return @{
                Success = $true
            }
        } -ArgumentList ('{0}\' -f $env:SystemDrive.TrimEnd('\'))

        if (-not (Wait-Job -Job $restorePointJob -Timeout $restorePointTimeoutSeconds)) {
            try {
                Stop-Job -Job $restorePointJob -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "Failed to stop timed-out restore-point job cleanly: $($_.Exception.Message)" 'WARN'
            }

            throw "Restore point creation timed out after $restorePointTimeoutSeconds seconds."
        }

        $restorePointResult = Receive-Job -Job $restorePointJob -ErrorAction Stop
        if ($null -eq $restorePointResult -or
            ($restorePointResult -is [hashtable] -and $restorePointResult.ContainsKey('Success') -and -not [bool]$restorePointResult.Success)) {
            throw 'Restore point job did not report success.'
        }

        Write-Log "Restore point created successfully"
        return $true
    } catch {
        Write-Log "Failed to create restore point : $_" 'ERROR'
        return $false
    } finally {
        if ($null -ne $restorePointJob) {
            try {
                Remove-Job -Job $restorePointJob -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "Failed to remove restore-point background job: $($_.Exception.Message)" 'WARN'
            }
        }

        if ($originalFrequencyExists) {
            if (-not (Set-RegistryValue -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -Value $originalFrequencyValue -Type 'DWord')) {
                Write-Log 'Failed to restore the original SystemRestorePointCreationFrequency value.' 'ERROR'
            }
        } else {
            Remove-RegistryValueIfPresent -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency'
            if (Test-Path $systemRestorePath) {
                try {
                    $leftoverFrequency = Get-ItemProperty -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop
                    if ($null -ne $leftoverFrequency) {
                        Write-Log 'Failed to remove the temporary SystemRestorePointCreationFrequency override.' 'ERROR'
                    }
                } catch [System.Management.Automation.ItemNotFoundException] {
                } catch {
                    Write-Log "Failed to verify cleanup of SystemRestorePointCreationFrequency: $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
}

function Invoke-VerifyInternetConnectivity {
    try {
        Write-Log 'Verifying internet connectivity...' 'INFO'

        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($null -ne $curl) {
            try {
                $curlOutput = & $curl.Source -L --fail --silent --show-error 'https://www.msftconnecttest.com/connecttest.txt' 2>$null
                if ($LASTEXITCODE -eq 0 -and [string]::Join("`n", @($curlOutput)) -match 'Microsoft Connect Test') {
                    Write-Log 'Internet connectivity verified (curl probe)' 'SUCCESS'
                    return $true
                }

                if ($LASTEXITCODE -ne 0) {
                    Write-Log "curl-based internet probe exited with code $LASTEXITCODE" 'WARN'
                }
            } catch {
                Write-Log "curl-based internet probe failed: $($_.Exception.Message)" 'WARN'
            }
        }

        try {
            $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -MaximumRedirection 3 -TimeoutSec 15 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$response.Content) -and [string]$response.Content -match 'Microsoft Connect Test') {
                Write-Log 'Internet connectivity verified (HTTP probe)' 'SUCCESS'
                return $true
            }
        } catch {
            Write-Log "HTTP internet probe failed: $($_.Exception.Message)" 'WARN'
        }

        try {
            if (Test-NetConnection -ComputerName 'raw.githubusercontent.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) {
                Write-Log 'Internet connectivity verified (TCP probe to raw.githubusercontent.com:443)' 'SUCCESS'
                return $true
            }
        } catch {
            Write-Log "TCP internet probe failed: $($_.Exception.Message)" 'WARN'
        }

        throw 'All connectivity probes failed.'
    } catch {
        Write-Log "Internet connectivity check failed: $_" 'ERROR'
        throw
    }
}

function Invoke-PreDownloadInstallers {
    try {
        Write-Log 'Starting background package download/install pipeline during preflight...' 'INFO'
        $launchResult = Invoke-ParallelInstalls -LaunchOnly
        Invoke-PrefetchExternalAssets
        return $launchResult
    } catch {
        Write-Log "Failed during pre-download : $_" 'ERROR'
        return $false
    }
}

# ==============================================================================
# PHASE 2 - CORE
# ==============================================================================

function Invoke-EnsureLocalStandardUser {
    if (Test-TaskCompleted -TaskId 'core-local-user-v2') {
        Write-Log "Local user already ensured, skipping"
        return $true
    }

    try {
        $localAccountsCommands = @(
            'Get-LocalUser',
            'New-LocalUser',
            'Set-LocalUser',
            'Enable-LocalUser',
            'Get-LocalGroupMember',
            'Remove-LocalGroupMember'
        )
        $canUseLocalAccountsModule = @($localAccountsCommands | Where-Object {
            $null -ne (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }).Count -eq $localAccountsCommands.Count
        $passwordContext = $null

        if ($canUseLocalAccountsModule) {
            $user = Get-LocalUser -Name 'user' -ErrorAction SilentlyContinue
            $passwordContext = Resolve-HunterLocalUserPassword -UserExists:($null -ne $user)

            if ($null -eq $user) {
                if ($null -eq $passwordContext -or [string]::IsNullOrWhiteSpace($passwordContext.Password)) {
                    throw "Hunter could not resolve a managed password for local user 'user'."
                }

                $password = ConvertTo-SecureString $passwordContext.Password -AsPlainText -Force
                New-LocalUser -Name 'user' -Password $password -FullName 'Standard User' -ErrorAction Stop
                Write-Log "Local user 'user' created"
            } else {
                if ($null -ne $passwordContext -and -not [string]::IsNullOrWhiteSpace($passwordContext.Password)) {
                    $password = ConvertTo-SecureString $passwordContext.Password -AsPlainText -Force
                    Set-LocalUser -Name 'user' -Password $password -FullName 'Standard User' -ErrorAction Stop
                } else {
                    Set-LocalUser -Name 'user' -FullName 'Standard User' -ErrorAction Stop
                    Write-Log "Existing local user 'user' retained its current password because Hunter has no managed credential for it." 'WARN'
                }

                if (-not $user.Enabled) {
                    Enable-LocalUser -Name 'user' -ErrorAction Stop
                }
                Write-Log "Local user 'user' normalized"
            }

            $adminGroup = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop |
                Where-Object { $_.Name -match '(^|\\)user$' })

            if ($adminGroup.Count -gt 0) {
                Remove-LocalGroupMember -Group 'Administrators' -Member 'user' -ErrorAction Stop
                Write-Log "Local user 'user' removed from Administrators"
            }
        } else {
            Write-Log 'LocalAccounts cmdlets unavailable; falling back to net.exe for local user management.' 'WARN'

            $computerName = $env:COMPUTERNAME
            $userAdsPath = "WinNT://$computerName/user,user"

            $testLocalUserExists = {
                try {
                    $matchingUsers = @(
                        Get-CimInstance -ClassName Win32_UserAccount `
                            -Filter "LocalAccount=True AND Name='user'" `
                            -ErrorAction Stop
                    )
                    return ($matchingUsers.Count -gt 0)
                } catch {
                    return $false
                }
            }

            $resolveLocalUserEntry = {
                try {
                    $entry = [ADSI]$userAdsPath
                    $null = $entry.Name
                    return $entry
                } catch {
                    return $null
                }
            }

            $invokeNetUser = {
                param([string[]]$Arguments)

                $stdoutPath = Join-Path $script:HunterRoot 'net-user.stdout.log'
                $stderrPath = Join-Path $script:HunterRoot 'net-user.stderr.log'

                foreach ($path in @($stdoutPath, $stderrPath)) {
                    if (Test-Path $path) {
                        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                    }
                }

                $process = Start-Process `
                    -FilePath 'net.exe' `
                    -ArgumentList $Arguments `
                    -NoNewWindow `
                    -Wait `
                    -PassThru `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError $stderrPath

                $outputLines = @()
                foreach ($path in @($stdoutPath, $stderrPath)) {
                    if (Test-Path $path) {
                        $outputLines += @(Get-Content -Path $path -ErrorAction SilentlyContinue)
                    }
                }

                return [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Output   = @($outputLines)
                }
            }

            $userExists = & $testLocalUserExists
            $passwordContext = Resolve-HunterLocalUserPassword -UserExists:$userExists
            $userEntry = if ($userExists) { & $resolveLocalUserEntry } else { $null }

            $netUserArgs = @('user', 'user')
            if ($null -ne $passwordContext -and -not [string]::IsNullOrWhiteSpace($passwordContext.Password)) {
                $netUserArgs += $passwordContext.Password
            } elseif (-not $userExists) {
                throw "Hunter could not resolve a managed password for local user 'user'."
            }

            if (-not $userExists) {
                $netUserArgs += '/add'
            }
            $netUserArgs += @('/active:yes', '/fullname:"Standard User"')

            $netUserResult = & $invokeNetUser -Arguments $netUserArgs
            $netUserOutput = @($netUserResult.Output)
            $netUserExitCode = [int]$netUserResult.ExitCode

            if ($netUserExitCode -eq 0) {
                if ($userExists) {
                    Write-Log "Local user 'user' normalized via net.exe"
                } else {
                    Write-Log "Local user 'user' created via net.exe"
                }
            } else {
                $netUserMessage = @(
                    $netUserOutput |
                        ForEach-Object { $_.ToString().Trim() } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                ) -join ' '
                if (-not [string]::IsNullOrWhiteSpace($netUserMessage)) {
                    Write-Log "net.exe fallback failed for local user 'user' (exit code $netUserExitCode): $netUserMessage" 'WARN'
                } else {
                    Write-Log "net.exe fallback failed for local user 'user' with exit code $netUserExitCode." 'WARN'
                }

                try {
                    $userEntry = & $resolveLocalUserEntry
                    if ($null -eq $userEntry) {
                        $computerEntry = [ADSI]"WinNT://$computerName,computer"
                        $userEntry = $computerEntry.Create('user', 'user')
                    }

                    if ($null -ne $passwordContext -and -not [string]::IsNullOrWhiteSpace($passwordContext.Password)) {
                        $userEntry.SetPassword($passwordContext.Password)
                    } elseif (-not $userExists) {
                        throw "ADSI fallback could not create local user 'user' without a managed password."
                    }

                    $userEntry.Put('FullName', 'Standard User')
                    $userEntry.SetInfo()

                    if ($userExists) {
                        Write-Log "Local user 'user' normalized via ADSI fallback"
                    } else {
                        Write-Log "Local user 'user' created via ADSI fallback"
                    }
                } catch {
                    if (-not [string]::IsNullOrWhiteSpace($netUserMessage)) {
                        throw "net.exe failed to provision the local user account with exit code $netUserExitCode. net.exe output: $netUserMessage. ADSI fallback failed: $($_.Exception.Message)"
                    }

                    throw "net.exe failed to provision the local user account with exit code $netUserExitCode. ADSI fallback failed: $($_.Exception.Message)"
                }
            }

            $userExists = & $testLocalUserExists
            $userEntry = & $resolveLocalUserEntry
            if ($userExists -and $null -ne $userEntry) {
                try {
                    $userFlags = [int]$userEntry.Get('UserFlags')
                    if (($userFlags -band 0x2) -ne 0) {
                        $userEntry.Put('UserFlags', ($userFlags -band (-bnot 0x2)))
                        $userEntry.SetInfo()
                        Write-Log "Local user 'user' enabled via ADSI"
                    }
                } catch {
                    Write-Log "Failed to ensure local user 'user' is enabled via ADSI: $($_.Exception.Message)" 'WARN'
                }
            }

            try {
                $administratorsGroup = [ADSI]"WinNT://$computerName/Administrators,group"
                $isAdministrator = [bool]$administratorsGroup.PSBase.Invoke('IsMember', $userAdsPath)
                if ($isAdministrator) {
                    $administratorsGroup.Remove($userAdsPath)
                    Write-Log "Local user 'user' removed from Administrators"
                }
            } catch {
                Write-Log "Failed to reconcile Administrators membership for local user 'user' : $($_.Exception.Message)" 'WARN'
            }
        }

        if ($null -ne $passwordContext -and -not [string]::IsNullOrWhiteSpace($passwordContext.Source)) {
            Write-Log "Managed local-user credential source: $($passwordContext.Source)" 'INFO'
        }

        return $true
    } catch {
        Write-Log "Failed to ensure local user : $_" 'ERROR'
        return $false
    }
}

function Invoke-ConfigureAutologin {
    if (Test-TaskCompleted -TaskId 'core-autologin-v2') {
        Write-Log "Autologin already configured, skipping"
        return (New-TaskSkipResult -Reason 'Autologin already configured')
    }

    if ($script:IsHyperVGuest) {
        Write-Log "Hyper-V guest detected, skipping autologin" 'INFO'
        return (New-TaskSkipResult -Reason 'Autologin is intentionally skipped on Hyper-V guests')
    }

    try {
        $passwordContext = Resolve-HunterLocalUserPassword -UserExists:$true
        if ($null -eq $passwordContext -or [string]::IsNullOrWhiteSpace($passwordContext.Password)) {
            Write-Log "Autologin was not configured because Hunter does not have a managed credential for local user 'user'." 'WARN'
            return (New-TaskSkipResult -Reason 'Autologin requires a managed local-user credential')
        }

        $autologonPath = Join-Path $script:DownloadDir 'Autologon64.exe'
        Download-File -Url 'https://live.sysinternals.com/Autologon64.exe' -Destination $autologonPath

        if (Test-Path $autologonPath) {
            Ensure-InstallerHelpersLoaded
            $validatedAutologonPath = Confirm-InstallerSignature -PackageName 'Autologon' -Path $autologonPath
            Invoke-NativeCommandChecked -FilePath $validatedAutologonPath -ArgumentList @('/accepteula', 'user', '.', $passwordContext.Password) | Out-Null
            Write-Log "Autologin configured"
            return $true
        } else {
            Write-Log "Autologon64.exe not found after download" 'ERROR'
            return $false
        }

    } catch {
        Write-Log "Failed to configure autologin : $_" 'ERROR'
        return $false
    }
}

function Invoke-EnableDarkMode {
    if (Test-TaskCompleted -TaskId 'core-dark-mode') {
        Write-Log "Dark mode already enabled, skipping"
        return
    }

    try {
        $themePath = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $themePath; Name = 'AppsUseLightTheme'; Value = 0 },
            @{ SubPath = $themePath; Name = 'SystemUsesLightTheme'; Value = 0 }
        )

        Request-ExplorerRestart
    } catch {
        Write-Log "Failed to enable dark mode : $_" 'ERROR'
    }
}

function Invoke-ActivateUltimatePerformance {
    try {
        $activeScheme = (powercfg /getactivescheme 2>$null) -join ''
        $upGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

        if ($activeScheme -match $upGuid) {
            Write-Log 'Ultimate Performance already active'
            return (New-TaskSkipResult -Reason 'Ultimate Performance is already active')
        }

        # Check if it already exists in the list
        $schemes = (powercfg /list 2>$null) -join "`n"
        if ($schemes -match $upGuid) {
            Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $upGuid) | Out-Null
        } else {
            # Duplicate the scheme - capture new GUID from output
            $result = powercfg /duplicatescheme $upGuid 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "powercfg /duplicatescheme exited with code $LASTEXITCODE"
            }
            $newGuid = $null
            $duplicateOutput = [string]::Join(' ', @($result))
            foreach ($token in ($duplicateOutput -split '\s+')) {
                $normalizedToken = $token.Replace('(', '').Replace(')', '')
                try {
                    $candidateGuid = [guid]$normalizedToken
                    $newGuid = $candidateGuid.Guid
                    break
                } catch {
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($newGuid)) {
                Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $newGuid) | Out-Null
            } else {
                # Fallback: try High Performance
                Write-Log 'Ultimate Performance not available, activating High Performance' 'WARN'
                Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') | Out-Null
            }
        }
        Write-Log 'Power scheme activated'
        return $true
    } catch {
        Write-Log "Failed to activate power plan: $_" 'ERROR'
        return $false
    }
}

# ==============================================================================
# PHASE 3 - START / UI
# ==============================================================================

function Invoke-DisableBingStartSearch {
    if (Test-TaskCompleted -TaskId 'startui-bing-search') {
        Write-Log "Bing search already disabled, skipping"
        return
    }

    try {
        $searchPath = 'Software\Microsoft\Windows\CurrentVersion\Search'
        $policyPath = 'SOFTWARE\Policies\Microsoft\Windows\Windows Search'

        Set-RegistryValue -Path "HKLM:\$policyPath" -Name 'DisableWebSearch' -Value 1 -Type DWord
        Set-RegistryValue -Path "HKLM:\$policyPath" -Name 'AllowCortana' -Value 0 -Type DWord

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $searchPath; Name = 'BingSearchEnabled'; Value = 0 },
            @{ SubPath = $searchPath; Name = 'CortanaConsent'; Value = 0 }
        )

    } catch {
        Write-Log "Failed to disable Bing search : $_" 'ERROR'
    }
}

function Invoke-DisableStartRecommendations {
    try {
        $advPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        $policyPath = 'Software\Policies\Microsoft\Windows\Explorer'
        $policyManagerStartPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
        $policyManagerEducationPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'
        $blockedStartPinsPatterns = Get-DefaultBlockedStartPinsPatterns

        if (-not (Clear-StaleStartCustomizationPolicies)) {
            return $false
        }

        # HKLM policy writes (WinUtil-aligned: 3 machine-level keys)
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name 'HideRecommendedSection' -Value 1 -Type DWord
        Set-RegistryValue -Path $policyManagerStartPath -Name 'HideRecommendedSection' -Value 1 -Type DWord
        Set-RegistryValue -Path $policyManagerEducationPath -Name 'IsEducationEnvironment' -Value 1 -Type DWord

        # Per-user registry writes (additional coverage beyond WinUtil)
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $advPath; Name = 'Start_IrisRecommendations'; Value = 0 },
            @{ SubPath = $advPath; Name = 'Start_AccountNotifications'; Value = 0 },
            @{ SubPath = $policyPath; Name = 'HideRecommendedSection'; Value = 1 }
        )

        # Verify every HKLM write — fail the task if any did not persist
        $verifyFailed = $false
        $verifyPairs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection'; Expected = 1 },
            @{ Path = $policyManagerStartPath; Name = 'HideRecommendedSection'; Expected = 1 },
            @{ Path = $policyManagerEducationPath; Name = 'IsEducationEnvironment'; Expected = 1 }
        )
        foreach ($v in $verifyPairs) {
            if (-not (Test-RegistryValue -Path $v.Path -Name $v.Name -ExpectedValue $v.Expected)) {
                Write-Log "VERIFY FAILED: $($v.Path)\$($v.Name) expected $($v.Expected) but did not read back" 'ERROR'
                $verifyFailed = $true
            }
        }

        # Also verify HKCU writes
        $hkcuVerifyPairs = @(
            @{ Path = "HKCU:\$advPath"; Name = 'Start_IrisRecommendations'; Expected = 0 },
            @{ Path = "HKCU:\$advPath"; Name = 'Start_AccountNotifications'; Expected = 0 },
            @{ Path = "HKCU:\$policyPath"; Name = 'HideRecommendedSection'; Expected = 1 }
        )
        foreach ($v in $hkcuVerifyPairs) {
            if (-not (Test-RegistryValue -Path $v.Path -Name $v.Name -ExpectedValue $v.Expected)) {
                Write-Log "VERIFY FAILED: $($v.Path)\$($v.Name) expected $($v.Expected) but did not read back" 'ERROR'
                $verifyFailed = $true
            }
        }

        if ($verifyFailed) {
            return $false
        }

        $liveCleanupResult = Invoke-ApplyLiveStartPinCleanup -BlockedPatterns $blockedStartPinsPatterns
        if (Test-TaskHandlerReturnedFailure -TaskResult $liveCleanupResult) {
            return $false
        }
        Request-ExplorerRestart
        return $liveCleanupResult
    } catch {
        Write-Log "Failed to disable Start recommendations : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableTaskbarSearchBox {
    if (Test-TaskCompleted -TaskId 'startui-search-box') {
        Write-Log "Taskbar search box already disabled, skipping"
        return
    }

    try {
        $searchPath = 'Software\Microsoft\Windows\CurrentVersion\Search'

        Set-DwordForAllUsers -SubPath $searchPath -Name 'SearchboxTaskbarMode' -Value 0

        Request-ExplorerRestart
    } catch {
        Write-Log "Failed to disable taskbar search box : $_" 'ERROR'
    }
}

function Invoke-DisableTaskViewButton {
    if (Test-TaskCompleted -TaskId 'startui-task-view') {
        Write-Log "Task view button already disabled, skipping"
        return
    }

    try {
        $advPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        Set-DwordForAllUsers -SubPath $advPath -Name 'ShowTaskViewButton' -Value 0

        Request-ExplorerRestart
    } catch {
        Write-Log "Failed to disable Task view button : $_" 'ERROR'
    }
}

function Invoke-DisableWidgets {
    if (Test-TaskCompleted -TaskId 'startui-widgets') {
        Write-Log "Widgets already disabled, skipping"
        return $true
    }

    try {
        Stop-Process -Name Widgets -Force -ErrorAction SilentlyContinue
        Remove-AppxPatterns -Patterns @('Microsoft.WidgetsPlatformRuntime*', 'MicrosoftWindows.Client.WebExperience*')

        # WinUtil parity: registry keys to fully disable Widgets
        $widgetsAdvancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        try {
            if (-not (Test-Path $widgetsAdvancedPath)) {
                New-Item -Path (Split-Path -Parent $widgetsAdvancedPath) -Name (Split-Path -Leaf $widgetsAdvancedPath) -Force | Out-Null
            }

            New-ItemProperty -Path $widgetsAdvancedPath -Name 'TaskbarDa' -Value 0 -PropertyType DWord -Force | Out-Null
            Write-Log "DWord set for current user: $widgetsAdvancedPath\TaskbarDa = 0"
        } catch {
            Write-Log "Skipping per-user Widgets taskbar flag update: $($_.Exception.Message)" 'WARN'
        }

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests' -Name 'value' -Value 0 -Type 'DWord'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to disable widgets : $_" 'ERROR'
        return $false
    }
}

function Invoke-EnableEndTaskOnTaskbar {
    if (Test-TaskCompleted -TaskId 'startui-end-task') {
        Write-Log "End Task on taskbar already enabled, skipping"
        return $true
    }

    try {
        $taskbarDevPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'

        Set-RegistryValue -Path "HKCU:\$taskbarDevPath" -Name 'TaskbarEndTask' -Value 1 -Type DWord
        if (-not (Test-RegistryValue -Path "HKCU:\$taskbarDevPath" -Name 'TaskbarEndTask' -ExpectedValue 1)) {
            throw 'TaskbarEndTask was not persisted for the current user.'
        }
        return $true
    } catch {
        Write-Log "Failed to enable End Task on taskbar : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableNotificationsTrayCalendar {
    if (Test-TaskCompleted -TaskId 'startui-notifications') {
        Write-Log "Notifications already disabled, skipping"
        return
    }

    try {
        $notificationsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
        $explorerPath = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'

        Set-RegistryValue -Path $notificationsPath -Name 'ToastEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $explorerPath -Name 'DisableNotificationCenter' -Value 1 -Type 'DWord'

        return $true

    } catch {
        Write-Log "Failed to disable notifications : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableNewOutlook {
    <#
    .SYNOPSIS
    Disables the new Outlook experience and prevents auto-migration.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/customize-preferences/newoutlook/
    #>
    try {
        Write-Log 'Disabling new Outlook toggle and auto-migration...' 'INFO'

        $prefsPath   = 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Preferences'
        $generalPath = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General'
        $policyGen   = 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Options\General'
        $policyPrefs = 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Preferences'

        # Disable new Outlook
        Set-RegistryValue -Path $prefsPath -Name 'UseNewOutlook' -Value 0 -Type 'DWord'

        # Hide the toggle in classic Outlook
        Set-RegistryValue -Path $generalPath -Name 'HideNewOutlookToggle' -Value 1 -Type 'DWord'

        # Prevent auto-migration via policy
        Set-RegistryValue -Path $policyGen -Name 'DoNewOutlookAutoMigration' -Value 0 -Type 'DWord'

        # Remove any user migration setting
        Remove-RegistryValueIfPresent -Path $policyPrefs -Name 'NewOutlookMigrationUserSetting'

        Write-Log 'New Outlook disabled.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to disable new Outlook: $_" 'ERROR'
        return $false
    }
}

function Invoke-HideSettingsHome {
    <#
    .SYNOPSIS
    Hides the Settings home page introduced in recent Windows 11 builds.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/customize-preferences/hidesettingshome/
    #>
    try {
        Write-Log 'Hiding Settings home page...' 'INFO'

        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'

        Set-RegistryValue -Path $regPath -Name 'SettingsPageVisibility' -Value 'hide:home' -Type 'String'

        Write-Log 'Settings home page hidden.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to hide Settings home: $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableStoreSearch {
    <#
    .SYNOPSIS
    Disables Microsoft Store results from appearing in Windows Search.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/essential-tweaks/disablestoresearch/
    #>
    try {
        Write-Log 'Disabling Microsoft Store search results...' 'INFO'

        $storeDbPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db'

        if (Test-Path $storeDbPath) {
            $icaclsResult = & icacls.exe $storeDbPath /deny 'Everyone:F' 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "icacls deny failed for store.db: $icaclsResult" 'WARN'
            } else {
                Write-Log "Microsoft Store search database locked via ACL." 'SUCCESS'
            }
        } else {
            Write-Log "Store database not found at $storeDbPath — Store may not be installed. Skipping." 'INFO'
        }

        return $true
    } catch {
        Write-Log "Failed to disable Store search: $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableIPv6 {
    <#
    .SYNOPSIS
    Fully disables IPv6 on all adapters via registry and adapter binding.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disableipv6/
    #>
    try {
        Write-Log 'Disabling IPv6...' 'INFO'

        # Set DisabledComponents = 255 (0xFF) to disable all IPv6 components
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
            -Name 'DisabledComponents' -Value 255 -Type 'DWord'

        # Disable IPv6 binding on all network adapters
        try {
            Disable-NetAdapterBinding -Name '*' -ComponentID 'ms_tcpip6' -ErrorAction Stop
            Write-Log 'IPv6 adapter bindings disabled on all adapters.' 'SUCCESS'
        } catch {
            Write-Log "Failed to disable IPv6 adapter binding: $($_.Exception.Message)" 'WARN'
        }

        Write-Log 'IPv6 disabled (DisabledComponents=255).' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to disable IPv6: $_" 'ERROR'
        return $false
    }
}

# ==============================================================================
# PHASE 4 - EXPLORER
# ==============================================================================

function Invoke-SetExplorerHomeThisPC {
    if (Test-TaskCompleted -TaskId 'explorer-home-thispc') {
        Write-Log "Explorer home already set to This PC, skipping"
        return
    }

    try {
        $advPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        Set-RegistryValue -Path $advPath -Name 'LaunchTo' -Value 1 -Type 'DWord'

        return $true
    } catch {
        Write-Log "Failed to set Explorer home to This PC : $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveExplorerHomeTab {
    try {
        $homeGuid = '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'
        Remove-ExplorerNamespaceAndVerify -Guid $homeGuid -DisplayName 'Home'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to remove Explorer Home tab : $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveExplorerGalleryTab {
    try {
        $galleryGuid = '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'
        Remove-ExplorerNamespaceAndVerify -Guid $galleryGuid -DisplayName 'Gallery'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to remove Explorer Gallery tab : $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveExplorerOneDriveTab {
    if (Test-TaskCompleted -TaskId 'explorer-remove-onedrive') {
        Write-Log "Explorer OneDrive tab already removed, skipping"
        return
    }

    try {
        $oneDriveGuid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
        Remove-ExplorerNamespaceAndVerify -Guid $oneDriveGuid -DisplayName 'OneDrive'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to remove Explorer OneDrive tab : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableExplorerAutoFolderDiscovery {
    if (Test-TaskCompleted -TaskId 'explorer-auto-discovery') {
        Write-Log "Explorer auto folder discovery already disabled, skipping"
        return
    }

    try {
        $bagsPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
        $bagMRUPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
        $shellPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'

        Remove-RegistryKey -Path $bagsPath
        Remove-RegistryKey -Path $bagMRUPath

        Set-RegistryValue -Path $shellPath -Name 'FolderType' -Value 'NotSpecified' -Type String

        Request-ExplorerRestart
    } catch {
        Write-Log "Failed to disable Explorer auto folder discovery : $_" 'ERROR'
    }
}
# ==============================================================================
# PHASE 5 - MICROSOFT / BROWSER / CLOUD REMOVAL
# ==============================================================================

function Invoke-RemoveEdgeKeepWebView2 {
    <#
    .SYNOPSIS
    Removes Microsoft Edge using the WinUtil uninstaller flow.
    .DESCRIPTION
    Unlocks the official Edge uninstaller stub and launches setup.exe with WinUtil arguments.
    #>
    param()

    try {
        Write-Log -Message "Unlocking the official Edge uninstaller and removing Microsoft Edge..." -Level 'INFO'

        $setupPath = Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        $edgeExecutablePaths = @(
            'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
        )
        if ([string]::IsNullOrWhiteSpace($setupPath)) {
            Write-Log -Message 'Edge installer was not found. Skipping Edge removal.' -Level 'INFO'
            return (New-TaskSkipResult -Reason 'Edge installer was not present')
        }

        New-Item 'C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe' -Force | Out-Null
        $edgeUninstall = Start-ProcessChecked `
            -FilePath $setupPath `
            -ArgumentList @('--uninstall', '--system-level', '--force-uninstall', '--delete-profile') `
            -SuccessExitCodes @(0, 19) `
            -WindowStyle Hidden

        $edgeStillInstalled = @($edgeExecutablePaths | Where-Object { Test-Path $_ }).Count -gt 0
        if ([int]$edgeUninstall.ExitCode -eq 19) {
            $warningMessage = 'Edge uninstaller exited with code 19.'
            if ($edgeStillInstalled) {
                Write-Log -Message "$warningMessage Edge still appears to be installed, so this step will be marked as skipped." -Level 'WARN'
                return (New-TaskSkipResult -Reason 'Edge uninstall was blocked by the current Windows build or installer state')
            }

            Write-Log -Message "$warningMessage Edge binaries are no longer present." -Level 'WARN'
            return $true
        }

        Write-Log -Message "Edge removal complete." -Level 'INFO'

        # Verify WebView2 runtime survived Edge removal
        $webView2RegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
        $webView2Exists = (Test-Path $webView2RegPath) -or
            (Test-Path 'C:\Program Files (x86)\Microsoft\EdgeWebView') -or
            (Test-Path 'C:\Program Files\Microsoft\EdgeWebView')
        if (-not $webView2Exists) {
            Write-Log -Message "WARNING: WebView2 runtime may have been removed alongside Edge. Some apps may not function correctly." -Level 'WARN'
        } else {
            Write-Log -Message "WebView2 runtime verified intact after Edge removal." -Level 'INFO'
        }

        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveEdgeKeepWebView2: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-RemoveEdgePinsAndShortcuts {
    <#
    .SYNOPSIS
    Removes Edge taskbar pins and shortcuts from desktop/start menu.
    #>
    param()

    try {
        Write-Log -Message "Removing Edge pins and shortcuts..." -Level 'INFO'

        $cleanupDefinition = Get-DefaultTaskbarCleanupDefinition

        # Remove taskbar pins
        Write-Log -Message "Removing Edge taskbar pins..." -Level 'INFO'
        if (Test-ShortcutPatternExists -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns) {
            Write-Log -Message "Removing Edge shortcuts..." -Level 'INFO'
        }
        $null = Invoke-RemoveDefaultTaskbarSurfaceArtifacts -RemoveEdgeShortcuts $true

        Request-ExplorerRestart
        Restart-StartSurface

        if (Test-TaskbarPinnedByShell -DisplayPatterns $cleanupDefinition.EdgePatterns -Paths $cleanupDefinition.EdgePaths) {
            throw 'Microsoft Edge is still pinned to the taskbar after cleanup'
        }

        if (Test-TaskbarPinnedByShell -DisplayPatterns $cleanupDefinition.StorePatterns -Paths $cleanupDefinition.StorePaths) {
            throw 'Microsoft Store is still pinned to the taskbar after cleanup'
        }

        if (Test-ShortcutPatternExists -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns) {
            Write-Log 'Edge shortcut remnants remain in the shell surface, but the taskbar pin has been removed.' 'WARN'
        }

        Write-Log -Message "Edge pins and shortcuts removal complete." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveEdgePinsAndShortcuts: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-RemoveOneDrive {
    <#
    .SYNOPSIS
    Removes OneDrive from the system.
    .DESCRIPTION
    Stops processes, uninstalls OneDrive, removes registry entries and directories.
    #>
    param()

    try {
        Write-Log -Message "Starting OneDrive removal..." -Level 'INFO'

        $programFilesRoot = $script:ProgramFilesRoot
        $oneDriveSetup32 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
        $oneDriveSetup64 = "$env:SystemRoot\System32\OneDriveSetup.exe"
        $oneDriveLocalAppData = "$env:LOCALAPPDATA\Microsoft\OneDrive"
        $oneDriveProgramFiles = Join-Path $programFilesRoot 'Microsoft OneDrive'
        $oneDriveUserFolder = $env:OneDrive
        $oneDriveGuid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'

        $getOneDriveMarkers = {
            $markers = New-Object 'System.Collections.Generic.List[string]'

            if (Test-Path $oneDriveLocalAppData) {
                [void]$markers.Add('LocalAppData')
            }

            if (Test-Path $oneDriveProgramFiles) {
                [void]$markers.Add('ProgramFiles')
            }

            if ((-not [string]::IsNullOrWhiteSpace($oneDriveUserFolder)) -and (Test-Path $oneDriveUserFolder)) {
                [void]$markers.Add('UserFolder')
            }

            if (Test-ExplorerNamespacePresent -Guid $oneDriveGuid) {
                [void]$markers.Add('ExplorerNamespace')
            }

            foreach ($executablePath in @(
                    "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
                    (Join-Path $oneDriveProgramFiles 'OneDrive.exe')
                )) {
                if (-not [string]::IsNullOrWhiteSpace($executablePath) -and (Test-Path $executablePath)) {
                    [void]$markers.Add("Executable:$executablePath")
                }
            }

            return [string[]]$markers.ToArray()
        }

        $detectedMarkers = @(& $getOneDriveMarkers)
        if ($detectedMarkers.Count -gt 0) {
            Write-Log -Message "OneDrive installation detected." -Level 'INFO'
        } else {
            Write-Log -Message "OneDrive not installed. Skipping." -Level 'INFO'
            return (New-TaskSkipResult -Reason 'OneDrive runtime artifacts were not present')
        }

        $oneDriveExecutablePaths = @(
            "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
            (Join-Path $oneDriveProgramFiles 'OneDrive.exe')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }

        foreach ($oneDriveExecutablePath in $oneDriveExecutablePaths) {
            try {
                Write-Log -Message "Shutting down OneDrive..." -Level 'INFO'
                Start-ProcessChecked -FilePath $oneDriveExecutablePath -ArgumentList @('/shutdown') -WindowStyle Hidden | Out-Null
                break
            } catch {
                Write-Log -Message "OneDrive shutdown attempt failed for $oneDriveExecutablePath : $_" -Level 'WARN'
            }
        }

        $aclOverrideApplied = $false
        if (-not [string]::IsNullOrWhiteSpace($oneDriveUserFolder) -and (Test-Path $oneDriveUserFolder)) {
            $denyRule = 'Administrators:(D,DC)'
            & icacls $oneDriveUserFolder /deny $denyRule 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $aclOverrideApplied = $true
            } else {
                Write-Log -Message "Failed to apply OneDrive folder ACL protection." -Level 'WARN'
            }
        }

        Write-Log -Message "Uninstalling OneDrive..." -Level 'INFO'
        $uninstallIssue = $null
        if (Test-Path $oneDriveSetup64) {
            try {
                $uninstallProcess = Start-Process -FilePath $oneDriveSetup64 -ArgumentList @('/uninstall') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -eq $uninstallProcess) {
                    throw "Failed to start process $oneDriveSetup64"
                }

                if ([int]$uninstallProcess.ExitCode -ne 0) {
                    $uninstallIssue = "$oneDriveSetup64 exited with code $($uninstallProcess.ExitCode)"
                    Write-Log -Message "OneDrive uninstaller reported a non-zero exit code: $uninstallIssue" -Level 'WARN'
                }
            } catch {
                $uninstallIssue = $_.Exception.Message
                Write-Log -Message "OneDrive uninstall attempt failed: $uninstallIssue" -Level 'WARN'
            }
        } elseif (Test-Path $oneDriveSetup32) {
            try {
                $uninstallProcess = Start-Process -FilePath $oneDriveSetup32 -ArgumentList @('/uninstall') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -eq $uninstallProcess) {
                    throw "Failed to start process $oneDriveSetup32"
                }

                if ([int]$uninstallProcess.ExitCode -ne 0) {
                    $uninstallIssue = "$oneDriveSetup32 exited with code $($uninstallProcess.ExitCode)"
                    Write-Log -Message "OneDrive uninstaller reported a non-zero exit code: $uninstallIssue" -Level 'WARN'
                }
            } catch {
                $uninstallIssue = $_.Exception.Message
                Write-Log -Message "OneDrive uninstall attempt failed: $uninstallIssue" -Level 'WARN'
            }
        } else {
            $uninstallIssue = 'OneDrive setup binary was not present; continuing with leftover cleanup only.'
            Write-Log -Message $uninstallIssue -Level 'WARN'
        }
        Start-Sleep -Seconds 3

        Write-Log -Message "Removing leftover OneDrive files..." -Level 'INFO'
        Stop-Process -Name 'FileCoAuth', 'explorer', 'OneDrive', 'OneDriveSetup' -Force -ErrorAction SilentlyContinue
        Remove-PathForce $oneDriveLocalAppData -WarnOnly
        Remove-PathForce "$env:ProgramData\Microsoft OneDrive" -WarnOnly
        Remove-PathForce $oneDriveProgramFiles -WarnOnly

        if ($aclOverrideApplied -and (Test-Path $oneDriveUserFolder)) {
            & icacls $oneDriveUserFolder /grant 'Administrators:(D,DC)' *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Log -Message "Failed to restore OneDrive folder ACLs." -Level 'WARN'
            }
        }

        Set-ServiceStartType -Name 'OneSyncSvc' -StartType Disabled
        Request-ExplorerRestart

        $remainingMarkers = @(& $getOneDriveMarkers)
        if ($remainingMarkers.Count -gt 0) {
            Write-Log -Message ("OneDrive removal incomplete. Remaining markers: {0}" -f ($remainingMarkers -join ', ')) -Level 'ERROR'
            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($uninstallIssue)) {
            Write-Log -Message "OneDrive removal completed with warnings after cleanup verification." -Level 'WARN'
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = $uninstallIssue
            }
        }

        Write-Log -Message "OneDrive removal complete." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveOneDrive: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableOneDriveFolderBackup {
    <#
    .SYNOPSIS
    Disables OneDrive folder backup (KFM - Known Folder Move).
    #>
    param()

    try {
        Write-Log -Message "Disabling OneDrive folder backup..." -Level 'INFO'

        # Pre-check
        $regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
        if ((Test-RegistryValue -Path $regPath -Name 'KFMBlockOptIn' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $regPath -Name 'KFMSilentOptIn' -ExpectedValue '')) {
            Write-Log -Message "OneDrive folder backup already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $regPath -Name 'KFMBlockOptIn' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $regPath -Name 'KFMSilentOptIn' -Value '' -Type 'String'

        Write-Log -Message "OneDrive folder backup disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableOneDriveFolderBackup: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-RemoveCopilot {
    <#
    .SYNOPSIS
    Removes Microsoft Copilot and related components.
    #>
    param()

    try {
        Write-Log -Message "Starting Copilot removal..." -Level 'INFO'

        $copilotAppxPatterns = @('Microsoft.Copilot*', 'Microsoft.Windows.Copilot*')
        $copilotRegistrySettings = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1; Type = 'DWord' },
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1; Type = 'DWord' },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; Value = 0; Type = 'DWord' },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot'; Name = 'IsCopilotAvailable'; Value = 0; Type = 'DWord' },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot'; Name = 'CopilotDisabledReason'; Value = 'IsEnabledForGeographicRegionFailed'; Type = 'String' },
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsCopilot'; Name = 'AllowCopilotRuntime'; Value = 0; Type = 'DWord' },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{CB3B0003-8088-4EDE-8769-8B354AB2FF8C}'; Value = ''; Type = 'String' },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat'; Name = 'IsUserEligible'; Value = 0; Type = 'DWord' }
        )

        Write-Log -Message "Removing Copilot Appx packages..." -Level 'INFO'
        Remove-AppxPatterns ($copilotAppxPatterns + @('Microsoft.MicrosoftOfficeHub*'))

        $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $coreAiPackage = Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.CoreAI*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $coreAiPackage -and -not [string]::IsNullOrWhiteSpace($currentUserSid)) {
            $coreAiEndOfLifePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife\$currentUserSid\$($coreAiPackage.PackageFullName)"
            New-Item -Path $coreAiEndOfLifePath -Force | Out-Null
            try {
                Remove-AppxPackage -Package $coreAiPackage.PackageFullName -ErrorAction Stop
            } catch {
                Write-Log -Message "Failed to remove CoreAI package $($coreAiPackage.PackageFullName): $_" -Level 'WARN'
            }
        }

        Write-Log -Message "Disabling Copilot via registry..." -Level 'INFO'
        foreach ($setting in $copilotRegistrySettings) {
            Set-RegistryValue -Path $setting.Path -Name $setting.Name -Value $setting.Value -Type $setting.Type
        }

        Get-Process -Name '*Copilot*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Request-ExplorerRestart

        Write-Log -Message "Copilot removal complete." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveCopilot: $_" -Level 'ERROR'
        return $false
    }
}

#endregion PHASE 5

#region PHASE 6 - APPS / FEATURES NUKE+BLOCK

function Invoke-NukeBlockApps {
    <#
    .SYNOPSIS
    NUKE+BLOCK pass: Remove multiple apps, services, scheduled tasks, and registry blocks.
    .DESCRIPTION
    Removes Outlook, LinkedIn, Xbox, Games, Feedback Hub, Office, Bing, Clipchamp, News, Teams, ToDo, Power Automate, Sound Recorder, Weather.
    #>
    param()

    try {
        Write-Log -Message "Starting comprehensive app NUKE+BLOCK removal..." -Level 'INFO'

        $startSurfaceShortcutDirs = @(((Get-DesktopShortcutDirectories) + (Get-StartMenuShortcutDirectories)) | Select-Object -Unique)
        $linkedInPatterns = @('*LinkedIn*', '*LinkedInForWindows*')
        $blockedStartPinsPatterns = Get-DefaultBlockedStartPinsPatterns

        # Consolidated AppX removal - single query for all patterns
        $allAppxRemovalPatterns = @(
            'Microsoft.OutlookForWindows*', 'microsoft.windowscommunicationsapps*',
            '*LinkedIn*', '*LinkedInForWindows*',
            'Microsoft.XboxIdentityProvider*', 'Microsoft.XboxSpeechToTextOverlay*',
            'Microsoft.GamingApp*', 'Microsoft.Xbox.TCUI*', 'Microsoft.XboxGamingOverlay*',
            'Microsoft.MicrosoftSolitaireCollection*', '*king.com*', '*CandyCrush*', '*BubbleWitch*', '*MarchofEmpires*',
            'Microsoft.WindowsFeedbackHub*',
            'Microsoft.MicrosoftOfficeHub*', 'Microsoft.Office.Desktop*',
            'Microsoft.BingSearch*', 'Microsoft.BingWeather*', 'Microsoft.BingNews*',
            'Microsoft.BingFinance*', 'Microsoft.BingSports*', 'Microsoft.MSN.Weather*',
            'Clipchamp.Clipchamp*', 'Microsoft.Clipchamp*',
            'Microsoft.News*',
            'MicrosoftTeams*', 'Microsoft.Teams*', 'MSTeams*',
            'Microsoft.Todos*',
            'Microsoft.PowerAutomateDesktop*',
            'Microsoft.WindowsSoundRecorder*'
        )
        Remove-AppxPatterns $allAppxRemovalPatterns

        # LinkedIn specific shortcut/unpin/start-menu operations
        Write-Log -Message "Removing LinkedIn shortcuts and pins..." -Level 'INFO'
        Invoke-StartMenuUnpinByPatterns -Patterns $linkedInPatterns
        Invoke-AppsFolderUninstallByPatterns -Patterns $linkedInPatterns
        Remove-ShortcutsByPattern -Directories $startSurfaceShortcutDirs -Patterns $linkedInPatterns

        # Disable Game DVR capture (WinUtil parity)
        Write-Log -Message "Disabling Xbox Game DVR..." -Level 'INFO'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 },
            @{ SubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Value = 0 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Value = 2 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; Value = 1 }
        )
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'ShowStartupPanel'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Value = 0 }
        )

        # Teams folder removal
        Write-Log -Message "Removing Teams folders..." -Level 'INFO'
        Remove-PathForce "$env:LOCALAPPDATA\Microsoft\Teams"
        Remove-RegistryValueIfPresent -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'com.squirrel.Teams.Teams'
        Remove-RegistryValueIfPresent -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams'
        Remove-ShortcutsByPattern -Directories $startSurfaceShortcutDirs -Patterns @('*Teams*')
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Teams\' -TaskName 'TeamsStartupTask' -DisplayName 'Teams startup task' | Out-Null

        # Start pins policy
        if (-not (Clear-StaleStartCustomizationPolicies)) {
            return $false
        }

        $liveCleanupResult = Invoke-ApplyLiveStartPinCleanup -BlockedPatterns $blockedStartPinsPatterns
        if (Test-TaskHandlerReturnedFailure -TaskResult $liveCleanupResult) {
            return $false
        }

        # Explorer/Start restart
        Request-ExplorerRestart

        # Verification checks
        if (Test-AppxPatternExists -Patterns $linkedInPatterns) {
            throw 'LinkedIn packages are still present after removal.'
        }

        if (Test-AppxPatternExists -Patterns @(
                'Microsoft.XboxIdentityProvider*',
                'Microsoft.XboxSpeechToTextOverlay*',
                'Microsoft.GamingApp*',
                'Microsoft.Xbox.TCUI*',
                'Microsoft.XboxGamingOverlay*'
            )) {
            throw 'Xbox or gaming AppX packages are still present after removal.'
        }

        Write-Log -Message "App NUKE+BLOCK removal complete." -Level 'INFO'
        return $liveCleanupResult
    }
    catch {
        Write-Log -Message "Error in Invoke-NukeBlockApps: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableInkingTyping {
    <#
    .SYNOPSIS
    Disables inking and typing personalization/telemetry.
    #>
    param()

    try {
        Write-Log -Message "Disabling inking and typing personalization..." -Level 'INFO'

        # Pre-check
        $inkingPath = 'HKCU:\Software\Microsoft\InputPersonalization'
        if ((Test-RegistryValue -Path $inkingPath -Name 'RestrictImplicitTextCollection' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $inkingPath -Name 'RestrictImplicitInkCollection' -ExpectedValue 1)) {
            Write-Log -Message "Inking/typing already disabled. Skipping." -Level 'INFO'
            return
        }

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Value = 0 }
        )
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' -Name 'AllowWindowsInkWorkspace' -Value 0 -Type DWord

        Write-Log -Message "Inking and typing personalization disabled." -Level 'INFO'
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableInkingTyping: $_" -Level 'ERROR'
    }
}

function Invoke-DisableDeliveryOptimization {
    <#
    .SYNOPSIS
    Disables Windows Delivery Optimization (P2P update downloads).
    #>
    param()

    try {
        Write-Log -Message "Disabling Delivery Optimization..." -Level 'INFO'

        # Pre-check
        $doPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        if (Test-RegistryValue -Path $doPath -Name 'DODownloadMode' -ExpectedValue 0) {
            Write-Log -Message "Delivery Optimization already disabled. Skipping." -Level 'INFO'
            return
        }

        Set-RegistryValue -Path $doPath -Name 'DODownloadMode' -Value 0 -Type 'DWord'

        Write-Log -Message "Delivery Optimization disabled." -Level 'INFO'
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableDeliveryOptimization: $_" -Level 'ERROR'
    }
}

function Invoke-DisableConsumerFeatures {
    <#
    .SYNOPSIS
    Disables Windows consumer features and cloud content.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/consumerfeatures/
    #>
    param()

    try {
        Write-Log -Message "Disabling Windows consumer features..." -Level 'INFO'

        # Pre-check
        $cloudPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        if ((Test-RegistryValue -Path $cloudPath -Name 'DisableWindowsConsumerFeatures' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $cloudPath -Name 'DisableSoftLanding' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $cloudPath -Name 'DisableWindowsSpotlightFeatures' -ExpectedValue 1) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SoftLandingEnabled' -ExpectedValue 0)) {
            Write-Log -Message "Consumer features already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $cloudPath -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $cloudPath -Name 'DisableSoftLanding' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $cloudPath -Name 'DisableWindowsSpotlightFeatures' -Value 1 -Type 'DWord'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'FeatureManagementEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OEMPreInstalledAppsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-314563Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353695Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353698Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-88000326Enabled'; Value = 0 }
        )

        Write-Log -Message "Windows consumer features disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableConsumerFeatures: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableActivityHistory {
    <#
    .SYNOPSIS
    Disables Windows activity history and user activity uploads.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/activity/
    #>
    param()

    try {
        Write-Log -Message "Disabling activity history..." -Level 'INFO'

        # Pre-check
        $systemPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        if ((Test-RegistryValue -Path $systemPath -Name 'EnableActivityFeed' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'PublishUserActivities' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'UploadUserActivities' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'AllowClipboardHistory' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'AllowCrossDeviceClipboard' -ExpectedValue 0)) {
            Write-Log -Message "Activity history already disabled. Skipping." -Level 'INFO'
            return
        }

        Set-RegistryValue -Path $systemPath -Name 'EnableActivityFeed' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'PublishUserActivities' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'UploadUserActivities' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'AllowClipboardHistory' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'AllowCrossDeviceClipboard' -Value 0 -Type 'DWord'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Clipboard'; Name = 'EnableCloudClipboard'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Clipboard'; Name = 'CloudClipboardAutomaticUpload'; Value = 0 }
        )

        Write-Log -Message "Activity history disabled." -Level 'INFO'
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableActivityHistory: $_" -Level 'ERROR'
    }
}

#endregion PHASE 6

#region PHASE 7 - TWEAKS

function Invoke-DisableTelemetry {
    <#
    .SYNOPSIS
    Disables Windows telemetry and diagnostic data collection.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/telemetry/
    #>
    param()

    try {
        Write-Log -Message "Disabling Windows telemetry..." -Level 'INFO'

        $dcPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'
        $systemPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        $svcHostPath = 'HKLM:\SYSTEM\CurrentControlSet\Control'
        $siufRulesPath = 'HKCU:\Software\Microsoft\Siuf\Rules'
        $werPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
        $splitThresholdKb = [int]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB)

        if ((Test-RegistryValue -Path $dcPath -Name 'AllowTelemetry' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPolicyPath -Name 'PublishUserActivities' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $svcHostPath -Name 'SvcHostSplitThresholdInKB' -ExpectedValue $splitThresholdKb) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Input\TIPC' -Name 'Enabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $siufRulesPath -Name 'NumberOfSIUFInPeriod' -ExpectedValue 0) -and
            (-not (Test-RegistryValue -Path $siufRulesPath -Name 'PeriodInNanoSeconds' -ExpectedValue $null)) -and
            (Test-RegistryValue -Path $dcPath -Name 'DoNotShowFeedbackNotifications' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $werPath -Name 'Disabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $werPath -Name 'DontShowUI' -ExpectedValue 1) -and
            (Test-ServiceStartTypeMatch -Name 'diagtrack' -ExpectedStartType 'Disabled') -and
            (Test-ServiceStartTypeMatch -Name 'WerSvc' -ExpectedStartType 'Disabled')) {
            Write-Log -Message "Telemetry already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $dcPath -Name 'AllowTelemetry' -Value 0 -Type 'DWord'

        Set-RegistryValue -Path $systemPolicyPath -Name 'PublishUserActivities' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $svcHostPath -Name 'SvcHostSplitThresholdInKB' -Value $splitThresholdKb -Type 'DWord'

        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Input\TIPC' -Name 'Enabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $siufRulesPath -Name 'NumberOfSIUFInPeriod' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $dcPath -Name 'DoNotShowFeedbackNotifications' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $werPath -Name 'Disabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $werPath -Name 'DontShowUI' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $systemPolicyPath -Name 'EnableSmartScreen' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPolicyPath -Name 'ShellSmartScreenLevel' -Value 'Off' -Type 'String'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\AppHost'; Name = 'EnableWebContentEvaluation'; Value = 0 }
        )
        Remove-ItemProperty -Path $siufRulesPath -Name 'PeriodInNanoSeconds' -ErrorAction SilentlyContinue

        Write-Log -Message "Disabling telemetry services..." -Level 'INFO'
        Set-ServiceStartType -Name 'diagtrack' -StartType 'Disabled'
        Set-ServiceStartType -Name 'dmwappushservice' -StartType 'Disabled'
        Set-ServiceStartType -Name 'WerSvc' -StartType 'Disabled'
        Stop-ServiceIfPresent -Name 'DiagTrack'
        Stop-ServiceIfPresent -Name 'dmwappushservice'
        Stop-ServiceIfPresent -Name 'WerSvc'

        Write-Log -Message "Disabling Defender telemetry..." -Level 'INFO'
        try {
            Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Could not set Defender telemetry preference: $_" -Level 'WARN'
        }

        Write-Log -Message "Windows telemetry disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableTelemetry: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableLocationTracking {
    <#
    .SYNOPSIS
    Disables Windows location tracking and related services.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/location/
    #>
    param()

    try {
        Write-Log -Message "Disabling location tracking..." -Level 'INFO'

        $locPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
        $sensorPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
        $lfsvcConfigurationPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
        $mapsPath = 'HKLM:\SYSTEM\Maps'

        if ((Test-RegistryValue -Path $locPath -Name 'Value' -ExpectedValue 'Deny') -and
            (Test-RegistryValue -Path $sensorPath -Name 'SensorPermissionState' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $lfsvcConfigurationPath -Name 'Status' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $mapsPath -Name 'AutoUpdateEnabled' -ExpectedValue 0)) {
            Write-Log -Message "Location tracking already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $locPath -Name 'Value' -Value 'Deny' -Type 'String'
        Set-RegistryValue -Path $sensorPath -Name 'SensorPermissionState' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $lfsvcConfigurationPath -Name 'Status' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $mapsPath -Name 'AutoUpdateEnabled' -Value 0 -Type 'DWord'

        Write-Log -Message "Location tracking disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableLocationTracking: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableHibernation {
    <#
    .SYNOPSIS
    Disables Windows hibernation mode.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/hiber/
    #>
    param()

    try {
        Write-Log -Message "Disabling hibernation..." -Level 'INFO'

        # Pre-check
        $powerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        if (Test-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -ExpectedValue 0) {
            Write-Log -Message "Hibernation already disabled. Skipping." -Level 'INFO'
            return
        }

        # Disable via powercfg
        Write-Log -Message "Running powercfg /h off..." -Level 'INFO'
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/h', 'off') | Out-Null

        # Registry settings
        Set-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' -Name 'ShowHibernateOption' -Value 0 -Type 'DWord'

        Write-Log -Message "Hibernation disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableHibernation: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableBackgroundApps {
    <#
    .SYNOPSIS
    Disables background app refresh globally.
    #>
    param()

    try {
        Write-Log -Message "Disabling background apps..." -Level 'INFO'

        # Pre-check
        $bgAppsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
        if ((Test-RegistryValue -Path $bgAppsPath -Name 'GlobalUserDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'DisableFileSyncNGSC' -ExpectedValue 1) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowWidgets' -ExpectedValue 0)) {
            Write-Log -Message "Background apps already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $bgAppsPath -Name 'GlobalUserDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowWidgets' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main' -Name 'AllowPrelaunch' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\TabPreloader' -Name 'AllowTabPreloading' -Value 0 -Type DWord

        Write-Log -Message "Background apps disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableBackgroundApps: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableTeredo {
    <#
    .SYNOPSIS
    Disables Windows Teredo IPv6 tunneling service.
    #>
    param()

    try {
        Write-Log -Message "Disabling Teredo..." -Level 'INFO'

        # Pre-check: Is Teredo already disabled?
        $teredoState = & netsh interface teredo show state 2>$null
        if ($teredoState -match 'offline|disabled') {
            Write-Log -Message "Teredo already disabled. Skipping." -Level 'INFO'
            return (New-TaskSkipResult -Reason 'Teredo already disabled')
        }

        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('interface', 'teredo', 'set', 'state', 'disabled') | Out-Null

        # Persist Teredo disable across reboots via registry (WinUtil parity)
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DisabledComponents' -Value 1 -Type 'DWord'

        Write-Log -Message "Teredo disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableTeredo: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableFullscreenOptimizations {
    <#
    .SYNOPSIS
    Disables DirectX fullscreen optimizations (GameDVR settings).
    #>
    param()

    try {
        Write-Log -Message "Disabling fullscreen optimizations..." -Level 'INFO'

        # Pre-check
        $gamePath = 'HKCU:\System\GameConfigStore'
        if ((Test-RegistryValue -Path $gamePath -Name 'GameDVR_DXGIHonorFSEWindowsCompatible' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $gamePath -Name 'GameDVR_Enabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $gamePath -Name 'GameDVR_FSEBehaviorMode' -ExpectedValue 2)) {
            Write-Log -Message "Fullscreen optimizations already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $gamePath -Name 'GameDVR_DXGIHonorFSEWindowsCompatible' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $gamePath -Name 'GameDVR_Enabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $gamePath -Name 'GameDVR_FSEBehaviorMode' -Value 2 -Type 'DWord'
        Set-RegistryValue -Path $gamePath -Name 'GameDVR_HonorUserFSEBehaviorMode' -Value 1 -Type 'DWord'

        Write-Log -Message "Fullscreen optimizations disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableFullscreenOptimizations: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-SetDwmFrameInterval {
    try {
        if (-not $script:IsHyperVGuest) {
            Write-Log 'Skipping DWMFRAMEINTERVAL on non-Hyper-V hardware.' 'INFO'
            return (New-TaskSkipResult -Reason 'DWMFRAMEINTERVAL applies only to Hyper-V guests')
        }

        $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations'
        if (Test-RegistryValue -Path $registryPath -Name 'DWMFRAMEINTERVAL' -ExpectedValue 15) {
            Write-Log 'DWMFRAMEINTERVAL already set to 15. Skipping.' 'INFO'
            return $true
        }

        Set-RegistryValue -Path $registryPath -Name 'DWMFRAMEINTERVAL' -Value 15 -Type DWord
        Write-Log 'DWMFRAMEINTERVAL set to 15.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to set DWMFRAMEINTERVAL: $_" 'ERROR'
        return $false
    }
}

function Invoke-BlockRazerSoftware {
    <#
    .SYNOPSIS
    Blocks Razer software installs via the WinUtil installer-folder ACL method.
    #>
    param()

    try {
        Write-Log -Message "Blocking Razer software..." -Level 'INFO'

        $razerPath = 'C:\Windows\Installer\Razer'

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name 'SearchOrderConfig' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' -Name 'DisableCoInstallers' -Value 1 -Type 'DWord'

        if (Test-Path $razerPath) {
            Remove-Item "$razerPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $razerPath -ItemType Directory -Force | Out-Null
        }

        & icacls $razerPath /deny 'Everyone:(W)' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to deny write access to the Razer installer path.'
        }

        Write-Log -Message "Razer software blocked." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-BlockRazerSoftware: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-BlockAdobeNetworkTraffic {
    <#
    .SYNOPSIS
    Blocks Adobe network traffic via hosts file.
    #>
    param()

    try {
        Write-Log -Message "Blocking Adobe network traffic..." -Level 'INFO'

        $adobeHosts = @(
            'ic-contrib.adobe.io',
            'cc-api-data.adobe.io',
            'notify.adobe.io',
            'prod.adobegenuine.com',
            'gocart.adobe.com',
            'genuine.adobe.com',
            'assets.adobedtm.com',
            'adobeereg.com',
            'activate.adobe.com',
            'practivate.adobe.com',
            'ereg.adobe.com',
            'wip3.adobe.com',
            'activate-sea.adobe.com',
            'activate-sjc0.adobe.com',
            '3dns-3.adobe.com',
            '3dns-2.adobe.com',
            'lm.licenses.adobe.com',
            'na1r.services.adobe.com',
            'hlrcv.stage.adobe.com',
            'lmlicenses.wip4.adobe.com',
            'na2m-stg1.services.adobe.com'
        )

        # Pre-check: Are Adobe hosts already blocked?
        $hostsFile = $script:HostsFilePath
        $hostsContent = Get-Content $hostsFile -ErrorAction SilentlyContinue
        $alreadyBlocked = $true
        foreach ($domain in $adobeHosts) {
            if (-not @($hostsContent | Where-Object { $_ -match [regex]::Escape($domain) })) {
                $alreadyBlocked = $false
                break
            }
        }

        if ($alreadyBlocked) {
            Write-Log -Message "Adobe hosts already blocked. Skipping." -Level 'INFO'
            return
        }

        Add-HostsEntries -Hostnames $adobeHosts

        Write-Log -Message "Adobe network traffic blocked." -Level 'INFO'
    }
    catch {
        Write-Log -Message "Error in Invoke-BlockAdobeNetworkTraffic: $_" -Level 'ERROR'
    }
}

function Invoke-SetServiceProfileManual {
    <#
    .SYNOPSIS
    Sets service startup types according to WinUtil recommended profile.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/services/
    #>
    param()

    try {
        Write-Log -Message "Setting service profiles to WinUtil recommended..." -Level 'INFO'

        $disabledServices = @(
            'AppVClient',
            'AssignedAccessManagerSvc',
            'BTAGService',
            'bthserv',
            'BthAvctpSvc',
            'DiagTrack',
            'DialogBlockingService',
            'DsSvc',                     # Data Sharing Service — inter-app data broker
            'DusmSvc',                   # Diagnostic Usage and Telemetry — usage data collection
            'GamingServices',            # Xbox / Game Pass integration (Xbox already nuked)
            'GamingServicesNet',         # Xbox network component (Xbox already nuked)
            'lfsvc',
            'MapsBroker',
            'midisrv',                   # MIDI Service — no MIDI controllers on gaming rigs
            'NetTcpPortSharing',
            'RemoteAccess',
            'RemoteRegistry',
            'RetailDemo',
            'SgrmBroker',               # System Guard Runtime Monitor — VBS component (HVCI already disabled)
            'shpamsvc',
            'ssh-agent',
            'SysMain',
            'TabletInputService',
            'tzautoupdate',
            'UevAgentService',
            'WbioSrvc',                 # Windows Biometric Service — not needed on gaming PCs
            'WerSvc',
            'WlanSvc',
            'WpcMonSvc',                # Parental Controls — not needed
            'WSearch',
            'wisvc',                     # Windows Insider Service — not needed
            'XblAuthManager',
            'xbgm',
            'XblGameSave',
            'XboxGipSvc',
            'XboxNetApiSvc'
        )

        $manualServices = @(
            'ALG',
            'Appinfo',
            'AppMgmt',
            'AppReadiness',
            'autotimesvc',
            'AxInstSV',
            'BDESVC',
            'camsvc',
            'CDPSvc',
            'CertPropSvc',
            'cloudidsvc',
            'COMSysApp',
            'CscService',
            'dcsvc',
            'defragsvc',
            'DeviceAssociationService',
            'DeviceInstall',
            'DevQueryBroker',
            'diagsvc',
            'DisplayEnhancementService',
            'dmwappushservice',
            'dot3svc',
            'EapHost',
            'edgeupdate',
            'edgeupdatem',
            'EFS',
            'fdPHost',
            'FDResPub',
            'fhsvc',
            'FrameServer',
            'FrameServerMonitor',
            'GraphicsPerfSvc',
            'hidserv',
            'HvHost',
            'icssvc',
            'IKEEXT',
            'InstallService',
            'InventorySvc',
            'IpxlatCfgSvc',
            'KtmRm',
            'LicenseManager',
            'lltdsvc',
            'lmhosts',
            'LxpSvc',
            'McpManagementService',
            'MicrosoftEdgeElevationService',
            'MSDTC',
            'MSiSCSI',
            'NaturalAuthentication',
            'NcaSvc',
            'NcbService',
            'NcdAutoSetup',
            'Netman',
            'netprofm',
            'NetSetupSvc',
            'NlaSvc',
            'PcaSvc',
            'PeerDistSvc',
            'perceptionsimulation',
            'PerfHost',
            'PhoneSvc',
            'pla',
            'PlugPlay',
            'PolicyAgent',
            'PrintNotify',
            'PushToInstall',
            'QWAVE',
            'RasAuto',
            'RasMan',
            'RmSvc',
            'RpcLocator',
            'SCardSvr',
            'ScDeviceEnum',
            'SCPolicySvc',
            'SDRSVC',
            'seclogon',
            'SEMgrSvc',
            'SensorDataService',
            'SensorService',
            'SensrSvc',
            'SessionEnv',
            'SharedAccess',
            'smphost',
            'SmsRouter',
            'SNMPTrap',
            'SNMPTRAP',
            'SSDPSRV',
            'SstpSvc',
            'StiSvc',
            'StorSvc',
            'svsvc',
            'swprv',
            'TapiSrv',
            'TermService',
            'TieringEngineService',
            'TokenBroker',
            'TroubleshootingSvc',
            'TrustedInstaller',
            'UmRdpService',
            'upnphost',
            'UsoSvc',
            'VaultSvc',
            'vds',
            'vmicguestinterface',
            'vmicheartbeat',
            'vmickvpexchange',
            'vmicrdv',
            'vmicshutdown',
            'vmictimesync',
            'vmicvmsession',
            'vmicvss',
            'VSS',
            'W32Time',
            'WalletService',
            'WarpJITSvc',
            'wbengine',
            'wcncsvc',
            'WdiServiceHost',
            'WdiSystemHost',
            'WebClient',
            'webthreatdefsvc',
            'Wecsvc',
            'WEPHOSTSVC',
            'wercplsupport',
            'WFDSConMgrSvc',
            'WiaRpc',
            'WinRM',
            'wlidsvc',
            'wlpasvc',
            'WManSvc',
            'wmiApSrv',
            'WMPNetworkSvc',
            'workfolderssvc',
            'WPDBusEnum',
            'WpnService',
            'WSAIFabricSvc',
            'wuauserv'
        )

        $automaticServices = @(
            'AudioEndpointBuilder',
            'Audiosrv',
            'AudioSrv',
            'CryptSvc',
            'Dhcp',
            'DispBrokerDesktopSvc',
            'DPS',
            'EventLog',
            'EventSystem',
            'FontCache',
            'iphlpsvc',
            'KeyIso',
            'LanmanServer',
            'LanmanWorkstation',
            'nsi',
            'Power',
            'ProfSvc',
            'SamSs',
            'SENS',
            'ShellHWDetection',
            'Themes',
            'TrkWks',
            'UserManager',
            'Wcmsvc',
            'Winmgmt'
        )

        $disablePrintSpooler = Test-ShouldDisablePrintSpooler
        if ($disablePrintSpooler) {
            $disabledServices += 'Spooler'
            Write-Log 'No printers detected; Print Spooler will be disabled.' 'INFO'
        } else {
            $automaticServices += 'Spooler'
            Write-Log 'Printer detected; Print Spooler will remain automatic.' 'INFO'
        }

        $autoDelayedServices = @('BITS')
        $alreadyConfigured = $true

        foreach ($svc in $disabledServices) {
            if (-not (Test-ServiceStartTypeMatch -Name $svc -ExpectedStartType 'Disabled')) {
                $alreadyConfigured = $false
                break
            }
        }

        if ($alreadyConfigured) {
            foreach ($svc in $manualServices) {
                if (-not (Test-ServiceStartTypeMatch -Name $svc -ExpectedStartType 'Manual')) {
                    $alreadyConfigured = $false
                    break
                }
            }
        }

        if ($alreadyConfigured) {
            foreach ($svc in $automaticServices) {
                if (-not (Test-ServiceStartTypeMatch -Name $svc -ExpectedStartType 'Automatic')) {
                    $alreadyConfigured = $false
                    break
                }
            }
        }

        if ($alreadyConfigured) {
            foreach ($svc in $autoDelayedServices) {
                if (-not (Test-ServiceAutomaticDelayedStart -Name $svc)) {
                    $alreadyConfigured = $false
                    break
                }
            }
        }

        if ($alreadyConfigured) {
            Write-Log -Message "Service profiles already configured. Skipping." -Level 'INFO'
            return $true
        }

        # Fire ALL service startup type changes concurrently via sc.exe
        Write-Log -Message "Firing all service startup type changes in parallel..." -Level 'INFO'
        $scProcs = New-Object 'System.Collections.Generic.List[object]'

        foreach ($svc in $disabledServices) {
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= disabled" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Disable service $svc" })
                }
            } catch { Write-Log "Failed to launch sc.exe for disabled service '$svc': $_" 'WARN' }
        }

        foreach ($svc in $manualServices) {
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= demand" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Set service $svc to demand start" })
                }
            } catch { Write-Log "Failed to launch sc.exe for manual service '$svc': $_" 'WARN' }
        }

        foreach ($svc in $automaticServices) {
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= auto" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Set service $svc to automatic start" })
                }
                # Clear delayed autostart flag concurrently
                $p2 = Start-Process -FilePath 'reg.exe' -ArgumentList "add `"HKLM\SYSTEM\CurrentControlSet\Services\$svc`" /v DelayedAutostart /t REG_DWORD /d 0 /f" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p2) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p2; Description = "Clear DelayedAutostart for $svc" })
                }
            } catch { Write-Log "Failed to launch sc.exe for automatic service '$svc': $_" 'WARN' }
        }

        foreach ($svc in $autoDelayedServices) {
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= delayed-auto" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Set service $svc to delayed-auto" })
                }
            } catch { Write-Log "Failed to launch sc.exe for delayed-auto service '$svc': $_" 'WARN' }
        }

        # Wait for all concurrent sc.exe / reg.exe operations (max 30s)
        $scDeadline = [DateTime]::UtcNow.AddSeconds(30)
        foreach ($procInfo in $scProcs) {
            $remainMs = [Math]::Max(1, [int]($scDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            try {
                if (-not $procInfo.Process.WaitForExit($remainMs)) {
                    Write-Log "$($procInfo.Description) timed out before completion." 'WARN'
                    continue
                }

                if ($procInfo.Process.ExitCode -ne 0) {
                    Write-Log "$($procInfo.Description) exited with code $($procInfo.Process.ExitCode)." 'WARN'
                }
            } catch {
                Write-Log "Failed to observe completion for $($procInfo.Description): $($_.Exception.Message)" 'WARN'
            }
        }

        foreach ($svc in @($disabledServices | Select-Object -Unique)) {
            Stop-ServiceIfPresent -Name $svc
        }

        Write-Log -Message "Service profiles set to WinUtil recommended ($($scProcs.Count) concurrent operations)." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-SetServiceProfileManual: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableVirtualizationSecurityOverhead {
    try {
        Write-Log 'Disabling virtualization security overhead...' 'INFO'

        $deviceGuardPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
        $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'

        Set-RegistryValue -Path $deviceGuardPath -Name 'EnableVirtualizationBasedSecurity' -Value 0 -Type DWord
        Set-RegistryValue -Path $deviceGuardPath -Name 'RequirePlatformSecurityFeatures' -Value 0 -Type DWord
        Set-RegistryValue -Path $hvciPath -Name 'Enabled' -Value 0 -Type DWord
        Set-RegistryValue -Path $hvciPath -Name 'Locked' -Value 0 -Type DWord
        Set-RegistryValue -Path $hvciPath -Name 'WasEnabledBy' -Value 0 -Type DWord

        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Virtual Machine Platform' -CandidateNames @('VirtualMachinePlatform') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Windows Hypervisor Platform' -CandidateNames @('HypervisorPlatform') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Hyper-V' -CandidateNames @('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Windows Sandbox' -CandidateNames @('Containers-DisposableClientVM') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Application Guard' -CandidateNames @('Windows-Defender-ApplicationGuard') | Out-Null

        Write-Log 'Virtualization security overhead disabled.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error disabling virtualization security overhead: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyGraphicsSchedulingTweaks {
    try {
        Write-Log 'Applying graphics scheduling and frame pacing tweaks...' 'INFO'

        $graphicsDriversPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $dwmPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'

        Set-RegistryValue -Path $graphicsDriversPath -Name 'HwSchMode' -Value 2 -Type DWord
        Set-RegistryValue -Path $graphicsDriversPath -Name 'TdrLevel' -Value 0 -Type DWord
        Set-RegistryValue -Path $graphicsDriversPath -Name 'TdrDelay' -Value 10 -Type DWord
        Set-RegistryValue -Path $graphicsDriversPath -Name 'TdrDdiDelay' -Value 10 -Type DWord
        Set-RegistryValue -Path $dwmPath -Name 'OverlayTestMode' -Value 5 -Type DWord

        Set-DirectXGlobalPreferenceValue -Key 'VRROptimizeEnable' -Value '1'
        Set-DirectXGlobalPreferenceValue -Key 'SwapEffectUpgradeEnable' -Value '1'
        Set-DirectXGlobalPreferenceValue -Key 'AutoHDREnable' -Value '0'

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'ShowStartupPanel'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Value = 0 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Value = 2 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; Value = 1 }
        )

        Write-Log 'Graphics scheduling and frame pacing tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying graphics scheduling tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyMemoryDiskBehaviorTweaks {
    try {
        Write-Log 'Applying memory and disk behavior tweaks...' 'INFO'

        $prefetchPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
        $memoryManagementPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

        Set-RegistryValue -Path $prefetchPath -Name 'EnablePrefetcher' -Value 0 -Type DWord
        Set-RegistryValue -Path $prefetchPath -Name 'EnableSuperfetch' -Value 0 -Type DWord
        Set-RegistryValue -Path $memoryManagementPath -Name 'LargeSystemCache' -Value 1 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Name 'AllowStorageSenseGlobal' -Value 0 -Type DWord
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '01'; Value = 0 }
        )

        try {
            Disable-MMAgent -MemoryCompression -ErrorAction Stop
            Write-Log 'Memory compression disabled.' 'INFO'
        } catch {
            Write-Log "Failed to disable memory compression: $($_.Exception.Message)" 'WARN'
        }

        try {
            Disable-MMAgent -PageCombining -ErrorAction Stop
            Write-Log 'Page combining disabled.' 'INFO'
        } catch {
            Write-Log "Failed to disable page combining: $($_.Exception.Message)" 'WARN'
        }

        try {
            Invoke-NativeCommandChecked -FilePath 'fsutil.exe' -ArgumentList @('behavior', 'set', 'disablelastaccess', '1') | Out-Null
            Write-Log 'NTFS last access updates disabled.' 'INFO'
        } catch {
            Write-Log "Failed to disable NTFS last access updates: $($_.Exception.Message)" 'WARN'
        }

        Write-Log 'Memory and disk behavior tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying memory and disk behavior tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyUiDesktopPerformanceTweaks {
    try {
        Write-Log 'Applying desktop compositor and UI performance tweaks...' 'INFO'

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'DisablePreviewDesktop'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'DisallowShaking'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableSnapAssistFlyout'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapAssist'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewAlphaSelect'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewShadow'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Value = 2 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'; Name = 'BackgroundType'; Value = 0 }
        )

        Set-StringForAllUsers -SubPath 'Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'WindowArrangementActive' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'SmoothScroll' -Value '0'

        Request-ExplorerRestart
        Write-Log 'Desktop compositor and UI performance tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying desktop compositor and UI tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyInputAndMaintenanceTweaks {
    try {
        Write-Log 'Applying input latency and maintenance tweaks...' 'INFO'

        Set-StringForAllUsers -SubPath 'Control Panel\Mouse' -Name 'MouseSpeed' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Accessibility\Keyboard Response' -Name 'Flags' -Value '0'

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' -Name 'MaintenanceDisabled' -Value 1 -Type DWord

        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\TaskScheduler\' -TaskName 'Regular Maintenance' -DisplayName 'Regular Maintenance' | Out-Null
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\TaskScheduler\' -TaskName 'Idle Maintenance' -DisplayName 'Idle Maintenance' | Out-Null
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\TaskScheduler\' -TaskName 'Maintenance Configurator' -DisplayName 'Maintenance Configurator' | Out-Null
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -DisplayName 'Scheduled Defrag' | Out-Null

        Invoke-BCDEditBestEffort -ArgumentList @('/deletevalue', 'useplatformclock') -Description 'HPET platform clock override removed.' | Out-Null
        Invoke-BCDEditBestEffort -ArgumentList @('/set', 'disabledynamictick', 'yes') -Description 'Dynamic ticks disabled.' | Out-Null

        Write-Log 'Input latency and maintenance tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying input and maintenance tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ExhaustivePowerTuning {
    <#
    .SYNOPSIS
    Applies the full WinSux exhaustive power-tuning profile.
    .DESCRIPTION
    Creates and activates the dedicated WinSux Ultimate Performance plan GUID, removes the
    remaining plans, applies the full powercfg AC/DC setting matrix from WinSux, and then
    layers on Hunter's additional per-device power-management disables for NIC/USB/HID/PCI.
    #>
    param()

    try {
        Write-Log 'Starting exhaustive power tuning...' 'INFO'

        $ultimatePerformanceGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        $winsuxPowerSchemeGuid = '99999999-9999-9999-9999-999999999999'

        $getPowerSchemeGuids = {
            $guidPattern = [regex]'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            $schemeGuids = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in @(& powercfg /L 2>$null)) {
                $match = $guidPattern.Match([string]$line)
                if (-not $match.Success) {
                    continue
                }

                $schemeGuid = $match.Value.ToLowerInvariant()
                if (-not $schemeGuids.Contains($schemeGuid)) {
                    [void]$schemeGuids.Add($schemeGuid)
                }
            }

            return @($schemeGuids.ToArray())
        }

        $existingSchemes = @(& $getPowerSchemeGuids)
        if ($existingSchemes -notcontains $winsuxPowerSchemeGuid.ToLowerInvariant()) {
            Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/duplicatescheme', $ultimatePerformanceGuid, $winsuxPowerSchemeGuid) | Out-Null
        }

        $existingSchemes = @(& $getPowerSchemeGuids)
        $activeSchemeGuid = if ($existingSchemes -contains $winsuxPowerSchemeGuid.ToLowerInvariant()) {
            $winsuxPowerSchemeGuid
        } elseif ($existingSchemes -contains $ultimatePerformanceGuid.ToLowerInvariant()) {
            Write-Log 'WinSux power scheme GUID could not be created; falling back to native Ultimate Performance.' 'WARN'
            $ultimatePerformanceGuid
        } else {
            Write-Log 'Ultimate Performance power scheme is unavailable; exhaustive power tuning cannot continue.' 'ERROR'
            return $false
        }

        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $activeSchemeGuid) | Out-Null

        foreach ($schemeGuid in @(& $getPowerSchemeGuids)) {
            if ($schemeGuid -eq $activeSchemeGuid.ToLowerInvariant()) {
                continue
            }

            try {
                Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/delete', $schemeGuid) | Out-Null
            } catch {
                Write-Log "Failed to delete power scheme ${schemeGuid}: $_" 'WARN'
            }
        }

        # ---- System-wide power registry settings ----

        # Disable hibernate and related shell power entries
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/hibernate', 'off') | Out-Null

        $powerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        if (-not (Test-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -ExpectedValue 0)) {
            Set-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -Value 0 -Type DWord
        }
        if (-not (Test-RegistryValue -Path $powerPath -Name 'HibernateEnabledDefault' -ExpectedValue 0)) {
            Set-RegistryValue -Path $powerPath -Name 'HibernateEnabledDefault' -Value 0 -Type DWord
        }

        $flyoutMenuSettingsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
        if (-not (Test-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowLockOption' -ExpectedValue 0)) {
            Set-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowLockOption' -Value 0 -Type DWord
        }
        if (-not (Test-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowSleepOption' -ExpectedValue 0)) {
            Set-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowSleepOption' -Value 0 -Type DWord
        }

        # Disable power throttling
        $ptPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
        if (-not (Test-RegistryValue -Path $ptPath -Name 'PowerThrottlingOff' -ExpectedValue 1)) {
            Set-RegistryValue -Path $ptPath -Name 'PowerThrottlingOff' -Value 1 -Type DWord
        } else {
            Write-Log 'Power throttling already disabled.' 'INFO'
        }

        # Disable fast boot (Hiberboot)
        $hbPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        if (-not (Test-RegistryValue -Path $hbPath -Name 'HiberbootEnabled' -ExpectedValue 0)) {
            Set-RegistryValue -Path $hbPath -Name 'HiberbootEnabled' -Value 0 -Type DWord
        } else {
            Write-Log 'Fast boot already disabled.' 'INFO'
        }

        # Unpark CPU cores - set max parking percentage to 100 (= never park)
        $coreUnparkPath = 'HKLM:\SYSTEM\ControlSet001\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583'
        if (-not (Test-RegistryValue -Path $coreUnparkPath -Name 'ValueMax' -ExpectedValue 100)) {
            Set-RegistryValue -Path $coreUnparkPath -Name 'ValueMax' -Value 100 -Type DWord
        } else {
            Write-Log 'CPU cores already unparked.' 'INFO'
        }

        # Enable global timer resolution requests
        Ensure-GlobalTimerResolutionRequestsEnabled -LogIfAlreadyEnabled | Out-Null

        $hubSelectiveSuspendTimeoutPath = 'HKLM:\SYSTEM\ControlSet001\Control\Power\PowerSettings\2a737441-1930-4402-8d77-b2bebba308a3\0853a681-27c8-4100-a2fd-82013e970683'
        if (-not (Test-RegistryValue -Path $hubSelectiveSuspendTimeoutPath -Name 'Attributes' -ExpectedValue 2)) {
            Set-RegistryValue -Path $hubSelectiveSuspendTimeoutPath -Name 'Attributes' -Value 2 -Type DWord
        }

        $usb3LinkPowerMgmtPath = 'HKLM:\SYSTEM\ControlSet001\Control\Power\PowerSettings\2a737441-1930-4402-8d77-b2bebba308a3\d4e98f31-5ffe-4ce1-be31-1b38b384c009'
        if (-not (Test-RegistryValue -Path $usb3LinkPowerMgmtPath -Name 'Attributes' -ExpectedValue 2)) {
            Set-RegistryValue -Path $usb3LinkPowerMgmtPath -Name 'Attributes' -Value 2 -Type DWord
        }

        # Disable console lock timeout (AC and DC)
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setacvalueindex', 'scheme_current', 'sub_none', 'consolelock', '0') | Out-Null
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setdcvalueindex', 'scheme_current', 'sub_none', 'consolelock', '0') | Out-Null
        Write-Log 'Console lock timeout disabled on AC and DC power.' 'INFO'

        $powerValueMatrix = @(
            @{ SubGroup = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Value = '0x00000000' },
            @{ SubGroup = '0d7dbae2-4294-402a-ba8e-26777e8488cd'; Setting = '309dce9b-bef4-4119-9921-a851fb12f0f4'; Value = '001' },
            @{ SubGroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; Value = '000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Value = '0x00000000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '94ac6d29-73ce-41a6-809f-6363ba21b47e'; Value = '000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Value = '0x00000000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'; Value = '000' },
            @{ SubGroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '0853a681-27c8-4100-a2fd-82013e970683'; Value = '0x00000000' },
            @{ SubGroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Value = '000' },
            @{ SubGroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'; Value = '000' },
            @{ SubGroup = '4f971e89-eebd-4455-a8de-9e59040e7347'; Setting = 'a7066653-8d6c-40a8-910e-a1f54b84c7e5'; Value = '002' },
            @{ SubGroup = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Value = '000' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Value = '000' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Value = '0x00000064' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'; Value = '001' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Value = '0x00000064' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Value = '600' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = 'aded5e82-b909-4619-9949-f5d71dac0bcb'; Value = '0x00000064' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = 'f1fbfde2-a960-4165-9f88-50667911ce96'; Value = '0x00000064' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = 'fbd9aa66-9553-4097-ba44-ed6e9d65eab8'; Value = '000' },
            @{ SubGroup = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; Setting = '10778347-1370-4ee0-8bbd-33bdacaade49'; Value = '001' },
            @{ SubGroup = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; Setting = '34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4'; Value = '000' },
            @{ SubGroup = '44f3beca-a7c0-460e-9df2-bb8b99e0cba6'; Setting = '3619c3f2-afb2-4afc-b0e9-e7fef372de36'; Value = '002' },
            @{ SubGroup = 'c763b4ec-0e50-4b6b-9bed-2b92a6ee884e'; Setting = '7ec1751b-60ed-4588-afb5-9819d3d77d90'; Value = '003' },
            @{ SubGroup = 'f693fb01-e858-4f00-b20f-f30e12ac06d6'; Setting = '191f65b5-d45c-4a4f-8aae-1ab8bfd980e6'; Value = '001' },
            @{ SubGroup = 'e276e160-7cb0-43c6-b20b-73f5dce39954'; Setting = 'a1662ab2-9d34-4e53-ba8b-2639b9e20857'; Value = '003' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '637ea02f-bbcb-4015-8e2c-a1c7b9c0b546'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '8183ba9a-e910-48da-8769-14ae6dc1170a'; Value = '0x00000000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469'; Value = '0x00000000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = 'bcded951-187b-4d05-bccc-f7e51960c258'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = 'd8742dcb-3e6a-4b3c-b3fe-374623cdcf06'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = 'f3c5027d-cd16-4930-aa6b-90db844a8f00'; Value = '0x00000000' },
            @{ SubGroup = 'de830923-a562-41af-a086-e3a2c6bad2da'; Setting = '13d09884-f74e-474a-a852-b6bde8ad03a8'; Value = '0x00000064' },
            @{ SubGroup = 'de830923-a562-41af-a086-e3a2c6bad2da'; Setting = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'; Value = '0x00000000' }
        )

        # ---- Fire powercfg matrix concurrently (all AC/DC pairs at once) ----
        $pcfgProcs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($pv in $powerValueMatrix) {
            try {
                $p1 = Start-Process -FilePath 'powercfg.exe' -ArgumentList "/setacvalueindex $activeSchemeGuid $($pv.SubGroup) $($pv.Setting) $($pv.Value)" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p1) {
                    [void]$pcfgProcs.Add([pscustomobject]@{ Process = $p1; Description = "powercfg AC $($pv.SubGroup)/$($pv.Setting)" })
                }
            } catch { Write-Log "Failed to launch powercfg AC for $($pv.SubGroup)/$($pv.Setting): $_" 'WARN' }
            try {
                $p2 = Start-Process -FilePath 'powercfg.exe' -ArgumentList "/setdcvalueindex $activeSchemeGuid $($pv.SubGroup) $($pv.Setting) $($pv.Value)" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p2) {
                    [void]$pcfgProcs.Add([pscustomobject]@{ Process = $p2; Description = "powercfg DC $($pv.SubGroup)/$($pv.Setting)" })
                }
            } catch { Write-Log "Failed to launch powercfg DC for $($pv.SubGroup)/$($pv.Setting): $_" 'WARN' }
        }
        Write-Log "Fired $($pcfgProcs.Count) concurrent powercfg operations." 'INFO'

        # ---- Fire device bus enumerations concurrently (USB/HID/PCI) ----
        $busEnumJobs = @()
        foreach ($bus in @('USB', 'HID', 'PCI')) {
            $busEnumJobs += Start-Job -ScriptBlock {
                param($busName)
                $busRoot = "HKLM:\SYSTEM\ControlSet001\Enum\$busName"
                $result = @{ Bus = $busName; DeviceParams = @(); WdfKeys = @() }
                if (-not (Test-Path $busRoot)) { return $result }
                $allKeys = @(Get-ChildItem -Path $busRoot -Recurse -ErrorAction SilentlyContinue)
                $result.DeviceParams = @($allKeys | Where-Object { $_.PSChildName -eq 'Device Parameters' } | ForEach-Object { $_.Name })
                $result.WdfKeys = @($allKeys | Where-Object { $_.PSChildName -eq 'WDF' } | ForEach-Object { $_.Name })
                return $result
            } -ArgumentList $bus
        }

        # ---- Enumerate NIC keys inline (fast, non-recursive) while jobs run ----
        $nicRegLines = [System.Collections.Generic.List[string]]::new()
        $nicBasePath = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
        $nicCount = 0
        if (Test-Path $nicBasePath) {
            $nicKeys = Get-ChildItem -Path $nicBasePath -ErrorAction SilentlyContinue
            foreach ($key in $nicKeys) {
                if ($key.PSChildName -notmatch '^\d{4}$') { continue }
                $regPath = $key.Name
                [void]$nicRegLines.Add("[$regPath]")
                [void]$nicRegLines.Add('"PnPCapabilities"=dword:00000018')
                [void]$nicRegLines.Add('"AdvancedEEE"="0"')
                [void]$nicRegLines.Add('"*EEE"="0"')
                [void]$nicRegLines.Add('"EEELinkAdvertisement"="0"')
                [void]$nicRegLines.Add('"SipsEnabled"="0"')
                [void]$nicRegLines.Add('"ULPMode"="0"')
                [void]$nicRegLines.Add('"GigaLite"="0"')
                [void]$nicRegLines.Add('"EnableGreenEthernet"="0"')
                [void]$nicRegLines.Add('"PowerSavingMode"="0"')
                [void]$nicRegLines.Add('"S5WakeOnLan"="0"')
                [void]$nicRegLines.Add('"*WakeOnMagicPacket"="0"')
                [void]$nicRegLines.Add('"*ModernStandbyWoLMagicPacket"="0"')
                [void]$nicRegLines.Add('"*WakeOnPattern"="0"')
                [void]$nicRegLines.Add('"WakeOnLink"="0"')
                [void]$nicRegLines.Add('')
                $nicCount++
            }
        }
        Write-Log "Prepared NIC power settings for $nicCount adapter(s)." 'INFO'

        # ---- Wait for powercfg matrix to complete, then reactivate scheme ----
        $pcfgDeadline = [DateTime]::UtcNow.AddSeconds(30)
        foreach ($procInfo in $pcfgProcs) {
            $remainMs = [Math]::Max(1, [int]($pcfgDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            try {
                if (-not $procInfo.Process.WaitForExit($remainMs)) {
                    Write-Log "$($procInfo.Description) timed out before completion." 'WARN'
                    continue
                }

                if ($procInfo.Process.ExitCode -ne 0) {
                    Write-Log "$($procInfo.Description) exited with code $($procInfo.Process.ExitCode)." 'WARN'
                }
            } catch {
                Write-Log "Failed to observe completion for $($procInfo.Description): $($_.Exception.Message)" 'WARN'
            }
        }
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $activeSchemeGuid) | Out-Null
        Write-Log 'Power value matrix applied and scheme reactivated.' 'INFO'

        # ---- Wait for device bus enumerations to complete ----
        $busEnumJobs | Wait-Job -Timeout 120 | Out-Null
        $busResults = @()
        foreach ($busJob in @($busEnumJobs)) {
            if ($busJob.State -ne 'Completed') {
                Write-Log "Device bus enumeration job '$($busJob.Name)' finished in state $($busJob.State)." 'WARN'
            }

            try {
                $receivedResult = Receive-Job -Job $busJob -ErrorAction Stop
                if ($null -ne $receivedResult) {
                    $busResults += @($receivedResult)
                }
            } catch {
                Write-Log "Failed to collect device bus enumeration job '$($busJob.Name)': $($_.Exception.Message)" 'WARN'
            }

            try {
                Remove-Job -Job $busJob -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to remove device bus enumeration job '$($busJob.Name)': $($_.Exception.Message)" 'WARN'
            }
        }

        # ---- Build combined .reg file (NIC + device buses) and import once ----
        $regContent = [System.Text.StringBuilder]::new()
        [void]$regContent.AppendLine('Windows Registry Editor Version 5.00')
        [void]$regContent.AppendLine()

        foreach ($line in $nicRegLines) {
            [void]$regContent.AppendLine($line)
        }

        $deviceEntryCount = 0
        foreach ($result in $busResults) {
            if ($null -eq $result -or $null -eq $result.DeviceParams) { continue }
            foreach ($regPath in $result.DeviceParams) {
                [void]$regContent.AppendLine("[$regPath]")
                [void]$regContent.AppendLine('"EnhancedPowerManagementEnabled"=dword:00000000')
                [void]$regContent.AppendLine('"SelectiveSuspendEnabled"=hex:00')
                [void]$regContent.AppendLine('"SelectiveSuspendOn"=dword:00000000')
                [void]$regContent.AppendLine('"WaitWakeEnabled"=dword:00000000')
                [void]$regContent.AppendLine()
                $deviceEntryCount++
            }
            foreach ($regPath in $result.WdfKeys) {
                [void]$regContent.AppendLine("[$regPath]")
                [void]$regContent.AppendLine('"IdleInWorkingState"=dword:00000000')
                [void]$regContent.AppendLine()
                $deviceEntryCount++
            }
            $busDevCount = $result.DeviceParams.Count + $result.WdfKeys.Count
            Write-Log "Enumerated $busDevCount device keys for $($result.Bus) bus." 'INFO'
        }

        $regFile = Join-Path $script:HunterRoot 'device-power-mgmt.reg'
        [System.IO.File]::WriteAllText($regFile, $regContent.ToString(), [System.Text.Encoding]::Unicode)
        try {
            $regImport = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', $regFile) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($null -eq $regImport -or $regImport.ExitCode -ne 0) {
                $exitCode = if ($null -ne $regImport) { $regImport.ExitCode } else { -1 }
                throw "reg import failed with exit code $exitCode"
            }
        } finally {
            Remove-Item -Path $regFile -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Device power management imported via .reg file ($nicCount NIC(s), $deviceEntryCount device entries)." 'INFO'

        Write-Log 'Exhaustive power tuning complete.' 'SUCCESS'
        return $true
    }
    catch {
        Write-Log "Error in Invoke-ExhaustivePowerTuning: $_" 'ERROR'
        return $false
    }
}

function Invoke-InstallTimerResolutionService {
    <#
    .SYNOPSIS
    Installs the WinSux-style timer resolution Windows service.
    .DESCRIPTION
    Builds a C# service that mirrors WinSux's process-aware timer resolution service. When no
    EXE-name INI is present beside the service binary, the service requests the maximum timer
    resolution continuously. When an INI exists, it raises the timer only while listed
    processes are running.
    #>
    param()

    try {
        Write-Log 'Installing timer resolution service...' 'INFO'

        $serviceName = 'SetTimerResolutionService'
        $displayName = 'Set Timer Resolution Service'
        $serviceDir = Join-Path $script:ProgramFilesRoot $serviceName
        $exePath = Join-Path $serviceDir "$serviceName.exe"
        $existingSvc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        Ensure-Directory $serviceDir

        if ($null -ne $existingSvc -and (Test-Path $exePath)) {
            Ensure-GlobalTimerResolutionRequestsEnabled | Out-Null

            if ($existingSvc.Status -ne 'Running') {
                try {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Start-Sleep -Milliseconds 500
                    $existingSvc = Get-Service -Name $serviceName -ErrorAction Stop
                } catch {
                    Write-Log "Existing timer resolution service could not be started cleanly and will be reinstalled: $($_.Exception.Message)" 'WARN'
                }
            }

            if ($null -ne $existingSvc -and $existingSvc.Status -eq 'Running') {
                Write-Log "Timer resolution service already installed and running ($exePath)." 'INFO'
                return (New-TaskSkipResult -Reason 'Timer resolution service already installed and running')
            }
        } elseif ($null -ne $existingSvc) {
            Write-Log 'Timer resolution service exists but its binary is missing; reinstalling it.' 'WARN'
        }

        # Compile the process-aware WinSux timer resolution service.
        $csSource = @'
using System;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.ComponentModel;
using System.Configuration.Install;
using System.Collections.Generic;
using System.Reflection;
using System.IO;
using System.Management;
using System.Threading;
using System.Diagnostics;
[assembly: AssemblyVersion("2.1")]
[assembly: AssemblyProduct("Set Timer Resolution service")]

namespace HunterTimerResolution
{
    public class SetTimerResolutionService : ServiceBase
    {
        public SetTimerResolutionService()
        {
            this.ServiceName = "SetTimerResolutionService";
            this.EventLog.Log = "Application";
            this.CanStop = true;
            this.CanHandlePowerEvent = false;
            this.CanHandleSessionChangeEvent = false;
            this.CanPauseAndContinue = false;
            this.CanShutdown = false;
        }

        public static void Main()
        {
            ServiceBase.Run(new SetTimerResolutionService());
        }

        protected override void OnStart(string[] args)
        {
            base.OnStart(args);
            ReadProcessList();
            NtQueryTimerResolution(out this.MinimumResolution, out this.MaximumResolution, out this.DefaultResolution);
            if (null != this.EventLog)
                try { this.EventLog.WriteEntry(String.Format("Minimum={0}; Maximum={1}; Default={2}; Processes='{3}'", this.MinimumResolution, this.MaximumResolution, this.DefaultResolution, null != this.ProcessesNames ? String.Join("','", this.ProcessesNames) : "")); }
                catch {}
            if (null == this.ProcessesNames)
            {
                SetMaximumResolution();
                return;
            }
            if (0 == this.ProcessesNames.Count)
            {
                return;
            }
            this.ProcessStartDelegate = new OnProcessStart(this.ProcessStarted);
            try
            {
                String query = String.Format("SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE (TargetInstance isa \"Win32_Process\") AND (TargetInstance.Name=\"{0}\")", String.Join("\" OR TargetInstance.Name=\"", this.ProcessesNames));
                this.startWatch = new ManagementEventWatcher(query);
                this.startWatch.EventArrived += this.startWatch_EventArrived;
                this.startWatch.Start();
            }
            catch (Exception ee)
            {
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Error); }
                    catch {}
            }
        }

        protected override void OnStop()
        {
            if (null != this.startWatch)
            {
                this.startWatch.Stop();
            }

            base.OnStop();
        }

        ManagementEventWatcher startWatch;
        void startWatch_EventArrived(object sender, EventArrivedEventArgs e)
        {
            try
            {
                ManagementBaseObject process = (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                UInt32 processId = (UInt32)process.Properties["ProcessId"].Value;
                this.ProcessStartDelegate.BeginInvoke(processId, null, null);
            }
            catch (Exception ee)
            {
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Warning); }
                    catch {}
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern Int32 WaitForSingleObject(IntPtr Handle, Int32 Milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(UInt32 DesiredAccess, Int32 InheritHandle, UInt32 ProcessId);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern Int32 CloseHandle(IntPtr Handle);
        const UInt32 SYNCHRONIZE = 0x00100000;

        delegate void OnProcessStart(UInt32 processId);
        OnProcessStart ProcessStartDelegate = null;

        void ProcessStarted(UInt32 processId)
        {
            SetMaximumResolution();
            IntPtr processHandle = IntPtr.Zero;
            try
            {
                processHandle = OpenProcess(SYNCHRONIZE, 0, processId);
                if (processHandle != IntPtr.Zero)
                    WaitForSingleObject(processHandle, -1);
            }
            catch (Exception ee)
            {
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Warning); }
                    catch {}
            }
            finally
            {
                if (processHandle != IntPtr.Zero)
                    CloseHandle(processHandle);
            }
            SetDefaultResolution();
        }

        List<String> ProcessesNames = null;
        void ReadProcessList()
        {
            String iniFilePath = Assembly.GetExecutingAssembly().Location + ".ini";
            if (File.Exists(iniFilePath))
            {
                this.ProcessesNames = new List<String>();
                String[] iniFileLines = File.ReadAllLines(iniFilePath);
                foreach (var line in iniFileLines)
                {
                    String[] names = line.Split(new char[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (var name in names)
                    {
                        String lowerName = name.ToLowerInvariant();
                        if (!lowerName.EndsWith(".exe"))
                            lowerName += ".exe";
                        if (!this.ProcessesNames.Contains(lowerName))
                            this.ProcessesNames.Add(lowerName);
                    }
                }
            }
        }

        [DllImport("ntdll.dll", SetLastError = true)]
        static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
        [DllImport("ntdll.dll", SetLastError = true)]
        static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint ActualResolution);

        uint DefaultResolution = 0;
        uint MinimumResolution = 0;
        uint MaximumResolution = 0;
        long processCounter = 0;

        void SetMaximumResolution()
        {
            long counter = Interlocked.Increment(ref this.processCounter);
            if (counter <= 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.MaximumResolution, true, out actual);
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(String.Format("Actual resolution = {0}", actual)); }
                    catch {}
            }
        }

        void SetDefaultResolution()
        {
            long counter = Interlocked.Decrement(ref this.processCounter);
            if (counter < 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.DefaultResolution, true, out actual);
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(String.Format("Actual resolution = {0}", actual)); }
                    catch {}
            }
        }
    }

    [RunInstaller(true)]
    public class TimerResolutionServiceInstaller : Installer
    {
        public TimerResolutionServiceInstaller()
        {
            ServiceProcessInstaller processInstaller = new ServiceProcessInstaller();
            ServiceInstaller serviceInstaller = new ServiceInstaller();
            processInstaller.Account = ServiceAccount.LocalSystem;
            processInstaller.Username = null;
            processInstaller.Password = null;
            serviceInstaller.DisplayName = "Set Timer Resolution Service";
            serviceInstaller.StartType = ServiceStartMode.Automatic;
            serviceInstaller.ServiceName = "SetTimerResolutionService";
            this.Installers.Add(processInstaller);
            this.Installers.Add(serviceInstaller);
        }
    }
}
'@

        $csFilePath = Join-Path $serviceDir "$serviceName.cs"
        Set-Content -Path $csFilePath -Value $csSource -Encoding UTF8 -Force

        # Find the C# compiler
        $cscPath = $null
        $frameworkDirs = @(
            "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319",
            "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
        )
        foreach ($dir in $frameworkDirs) {
            $candidate = Join-Path $dir 'csc.exe'
            if (Test-Path $candidate) {
                $cscPath = $candidate
                break
            }
        }

        if ($null -eq $cscPath) {
            Write-Log 'C# compiler (csc.exe) not found - cannot build timer resolution service.' 'ERROR'
            return $false
        }

        # Compile the service
        $compileOutput = & $cscPath `
            /nologo `
            /out:$exePath `
            /target:exe `
            /reference:System.ServiceProcess.dll `
            /reference:System.Configuration.Install.dll `
            /reference:System.Management.dll `
            $csFilePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Timer resolution service compilation failed: $($compileOutput -join ' ')" 'ERROR'
            return $false
        }

        if (-not (Test-Path $exePath)) {
            Write-Log "Timer resolution service compilation did not produce $exePath." 'ERROR'
            return $false
        }

        Write-Log 'Timer resolution service compiled successfully.' 'INFO'
        Remove-Item -Path $csFilePath -Force -ErrorAction SilentlyContinue

        if ($null -ne $existingSvc) {
            if ($existingSvc.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
            Invoke-NativeCommandChecked -FilePath 'sc.exe' -ArgumentList @('delete', $serviceName) | Out-Null
            Start-Sleep -Seconds 2
        }

        New-Service -Name $serviceName -BinaryPathName ('"{0}"' -f $exePath) -DisplayName $displayName -StartupType Automatic -ErrorAction Stop | Out-Null
        Invoke-NativeCommandChecked -FilePath 'sc.exe' -ArgumentList @('description', $serviceName, 'Mirrors the WinSux timer-resolution service and holds the system timer at maximum resolution, or only while configured processes are running.') | Out-Null
        Start-Service -Name $serviceName -ErrorAction Stop

        Ensure-GlobalTimerResolutionRequestsEnabled | Out-Null

        try {
            Invoke-NativeCommandChecked -FilePath 'cmd.exe' -ArgumentList @('/c', 'cd /d %systemroot%\system32 && lodctr /R >nul 2>&1') | Out-Null
        } catch {
            Write-Log "Failed to rebuild 64-bit performance counters: $_" 'WARN'
        }
        try {
            Invoke-NativeCommandChecked -FilePath 'cmd.exe' -ArgumentList @('/c', 'cd /d %systemroot%\sysWOW64 && lodctr /R >nul 2>&1') | Out-Null
        } catch {
            Write-Log "Failed to rebuild 32-bit performance counters: $_" 'WARN'
        }

        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq 'Running') {
            Write-Log "Timer resolution service installed and running ($exePath)." 'SUCCESS'
            return $true
        } else {
            Write-Log "Timer resolution service did not reach Running state after installation." 'ERROR'
            return $false
        }
    }
    catch {
        Write-Log "Error in Invoke-InstallTimerResolutionService: $_" 'ERROR'
        return $false
    }
}

#endregion PHASE 7

#region INSTALL PIPELINE

function Invoke-CollectCompletedParallelInstallJobs {
    try {
        if ($script:ParallelInstallJobs.Count -eq 0) {
            return
        }

        $remainingJobs = @()
        foreach ($jobInfo in @($script:ParallelInstallJobs)) {
            if ($jobInfo.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
                $remainingJobs += $jobInfo
                continue
            }

            $elapsed = Format-ElapsedDuration -Duration ((Get-Date) - $jobInfo.StartedAt)
            $jobState = $jobInfo.Job.State
            Write-Log "Background installer completed during task execution: $($jobInfo.Target.PackageName) [$jobState] after $elapsed" 'INFO'
            $jobResult = Receive-ParallelInstallerJobResult -JobInfo $jobInfo -ResultsByPackageId $script:ParallelInstallResults
            $level = if ($jobResult.Success) { 'SUCCESS' } else { 'ERROR' }
            Write-Log "Background installer result: $($jobInfo.Target.PackageName) - $($jobResult.Message)" $level
        }

        $script:ParallelInstallJobs = @($remainingJobs)
    } catch {
        Write-Log "Failed to collect completed background installer jobs: $($_.Exception.Message)" 'WARN'
    }
}

function Receive-ParallelInstallerJobResult {
    param(
        [object]$JobInfo,
        [hashtable]$ResultsByPackageId
    )

    $packageResult = @{
        PackageId = $JobInfo.Target.PackageId
        PackageName = $JobInfo.Target.PackageName
        Success = $false
        Message = ''
        Skipped = $false
        PathEntries = @()
    }

    try {
        $jobReceiveErrors = @()
        $jobOutput = @(Receive-Job -Job $JobInfo.Job -Keep -ErrorAction Continue -ErrorVariable +jobReceiveErrors)
        $result = $null
        foreach ($outputItem in $jobOutput) {
            if ($null -eq $outputItem) {
                continue
            }

            if ($outputItem -is [System.Collections.IDictionary] -and
                $outputItem.Contains('PackageId') -and
                $outputItem.Contains('Success') -and
                $outputItem.Contains('Message')) {
                $result = [pscustomobject]$outputItem
                continue
            }

            $propertyNames = @($outputItem.PSObject.Properties | Select-Object -ExpandProperty Name)
            if (($propertyNames -contains 'PackageId') -and
                ($propertyNames -contains 'Success') -and
                ($propertyNames -contains 'Message')) {
                $result = $outputItem
            }
        }

        if ($null -eq $result) {
            $verifiedExecutablePath = $null
            $verificationTimeoutSeconds = if ($JobInfo.Target.ContainsKey('VerificationTimeoutSeconds') -and [int]$JobInfo.Target.VerificationTimeoutSeconds -gt 0) {
                [int]$JobInfo.Target.VerificationTimeoutSeconds
            } else {
                10
            }
            if ($JobInfo.Target.ContainsKey('GetExecutable') -and $null -ne $JobInfo.Target.GetExecutable) {
                try {
                    $verifiedExecutablePath = Wait-ForExecutablePath -Resolver $JobInfo.Target.GetExecutable -TimeoutSeconds $verificationTimeoutSeconds
                    if ($JobInfo.Target.PackageId -eq 'cinebench-r23' -and (Test-IsLegacyHunterCinebenchPath -Path $verifiedExecutablePath)) {
                        $verifiedExecutablePath = $null
                    }
                } catch {
                    Write-Log "Executable verification failed for $($JobInfo.Target.PackageName): $_" 'WARN'
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($verifiedExecutablePath) -and (Test-Path $verifiedExecutablePath)) {
                $JobInfo.Target['ExistingExecutablePath'] = $verifiedExecutablePath
                $packageResult.Success = $true
                $packageResult.Message = "$($JobInfo.Target.PackageName) installation verified after background job completion"
                $ResultsByPackageId[$JobInfo.Target.PackageId] = @{
                    Success = $packageResult.Success
                    Message = $packageResult.Message
                    Skipped = $packageResult.Skipped
                    PathEntries = @($packageResult.PathEntries)
                }
                return [pscustomobject]$packageResult
            }

            $jobMessages = @($jobOutput | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
            $jobMessages += @($jobReceiveErrors | ForEach-Object { $_.ToString() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $jobMessages += @($JobInfo.Job.ChildJobs | ForEach-Object { $_.Error } | ForEach-Object { $_.ToString() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($null -ne $JobInfo.Job.JobStateInfo.Reason) {
                $jobMessages += $JobInfo.Job.JobStateInfo.Reason.ToString()
            }

            $jobMessage = @($jobMessages | Select-Object -Unique) -join ' | '
            if ([string]::IsNullOrWhiteSpace($jobMessage)) {
                $jobMessage = 'No result returned from installer job.'
            }

            $packageResult.Message = $jobMessage
            $ResultsByPackageId[$JobInfo.Target.PackageId] = @{
                Success = $packageResult.Success
                Message = $packageResult.Message
                Skipped = $packageResult.Skipped
                PathEntries = @($packageResult.PathEntries)
            }
            return [pscustomobject]$packageResult
        }

        $packageResult.Success = [bool]$result.Success
        $packageResult.Message = [string]$result.Message
        $packageResult.Skipped = [bool]$result.Skipped
        if ($result.PSObject.Properties['PathEntries']) {
            $packageResult.PathEntries = @($result.PathEntries | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_)
            } | Select-Object -Unique)
        }

        if (-not $packageResult.Success -and $JobInfo.Target.ContainsKey('GetExecutable') -and $null -ne $JobInfo.Target.GetExecutable) {
            $existingExecutablePath = $null
            $verificationTimeoutSeconds = if ($JobInfo.Target.ContainsKey('VerificationTimeoutSeconds') -and [int]$JobInfo.Target.VerificationTimeoutSeconds -gt 0) {
                [int]$JobInfo.Target.VerificationTimeoutSeconds
            } else {
                10
            }
            try {
                $existingExecutablePath = Wait-ForExecutablePath -Resolver $JobInfo.Target.GetExecutable -TimeoutSeconds $verificationTimeoutSeconds
                if ($JobInfo.Target.PackageId -eq 'cinebench-r23' -and (Test-IsLegacyHunterCinebenchPath -Path $existingExecutablePath)) {
                    $existingExecutablePath = $null
                }
            } catch {
                Write-Log "Pre-install executable check failed for $($JobInfo.Target.PackageName): $_" 'WARN'
            }

            if (-not [string]::IsNullOrWhiteSpace($existingExecutablePath) -and (Test-Path $existingExecutablePath)) {
                $JobInfo.Target['ExistingExecutablePath'] = $existingExecutablePath
                $packageResult.Success = $true
                $packageResult.Message = "$($JobInfo.Target.PackageName) installation verified after background job completion"
            }
        }

        foreach ($pathEntry in @($packageResult.PathEntries)) {
            Add-MachinePathEntry -PathEntry $pathEntry
        }

        $ResultsByPackageId[$JobInfo.Target.PackageId] = @{
            Success = $packageResult.Success
            Message = $packageResult.Message
            Skipped = $packageResult.Skipped
            PathEntries = @($packageResult.PathEntries)
        }
    } catch {
        $packageResult.Message = $_.Exception.Message
        $ResultsByPackageId[$JobInfo.Target.PackageId] = @{
            Success = $packageResult.Success
            Message = $packageResult.Message
            Skipped = $packageResult.Skipped
            PathEntries = @($packageResult.PathEntries)
        }
    } finally {
        Remove-Job -Job $JobInfo.Job -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]$packageResult
}

function Invoke-ParallelInstalls {
    <#
    .SYNOPSIS
    Launches package installations in parallel and optionally waits for completion.
    .DESCRIPTION
    Uses Start-Job with self-contained scriptblocks for reliable parallel execution.
    Each job contains the minimal download/install logic it needs, while package
    metadata, verification, shortcuts, and pinning stay in the shared main-thread catalog.
    #>
    param(
        [switch]$LaunchOnly
    )

    try {
        if ($null -eq $script:PostInstallCompletion) {
            $script:PostInstallCompletion = @{}
        }

        if ($script:ParallelInstallJobs.Count -eq 0) {
            Write-Log "Preparing parallel installer pipeline..." 'INFO'

            $script:ParallelInstallTargets = @()
            $script:ParallelInstallJobs = @()
            $script:ParallelInstallResults = @{}

            foreach ($target in @(Get-InstallTargetCatalog)) {
                if ($target.PackageId -eq 'cinebench-r23') {
                    Remove-LegacyHunterCinebenchPayload
                }

                $resolvedTarget = @{} + $target
                $existingExecutablePath = & $target.GetExecutable
                if ($target.PackageId -eq 'cinebench-r23' -and (Test-IsLegacyHunterCinebenchPath -Path $existingExecutablePath)) {
                    $existingExecutablePath = $null
                }
                if (-not [string]::IsNullOrWhiteSpace($existingExecutablePath) -and (Test-Path $existingExecutablePath)) {
                    $resolvedTarget.ExistingExecutablePath = $existingExecutablePath
                    $script:ParallelInstallResults[$target.PackageId] = @{
                        Success = $true
                        Message = "$($target.PackageName) already installed"
                        Skipped = $true
                    }
                    Write-Log "$($target.PackageName) already installed. Reusing existing installation." 'INFO'
                    $script:ParallelInstallTargets += $resolvedTarget
                    continue
                }

                try {
                    $resolvedTarget.WingetSource = if ($target.ContainsKey('WingetSource') -and -not [string]::IsNullOrWhiteSpace($target.WingetSource)) {
                        $target.WingetSource
                    } else {
                        'winget'
                    }
                    $resolvedTarget.WingetUseId = if ($target.ContainsKey('WingetUseId')) {
                        [bool]$target.WingetUseId
                    } else {
                        $true
                    }
                    $resolvedTarget.AllowDirectDownloadFallback = if ($target.ContainsKey('AllowDirectDownloadFallback')) {
                        [bool]$target.AllowDirectDownloadFallback
                    } else {
                        $true
                    }
                    $resolvedTarget.DownloadUrl = ''
                    $resolvedTarget.DownloadFileName = ''

                    $requiresDownloadSpec = $resolvedTarget.SkipWinget -or $resolvedTarget.AllowDirectDownloadFallback
                    if ($requiresDownloadSpec) {
                        if (-not $target.ContainsKey('GetDownloadSpec') -or $null -eq $target.GetDownloadSpec) {
                            throw "No download resolver configured for $($target.PackageName)"
                        }

                        $downloadSpec = & $target.GetDownloadSpec
                        if ($null -eq $downloadSpec -or [string]::IsNullOrWhiteSpace($downloadSpec.Url) -or [string]::IsNullOrWhiteSpace($downloadSpec.FileName)) {
                            throw "Download resolver returned no usable download spec for $($target.PackageName)"
                        }

                        $resolvedTarget.DownloadUrl = $downloadSpec.Url
                        $resolvedTarget.DownloadFileName = $downloadSpec.FileName
                    }
                } catch {
                    Write-Log "Failed to resolve install source for $($target.PackageName) : $_" 'ERROR'
                    return $false
                }

                $script:ParallelInstallTargets += $resolvedTarget

                # Collect any already-finished jobs to free resources, but never block
                Invoke-CollectCompletedParallelInstallJobs

                $jobTarget = @{
                    PackageId                  = $resolvedTarget.PackageId
                    PackageName                = $resolvedTarget.PackageName
                    WingetId                   = $resolvedTarget.WingetId
                    WingetSource               = $resolvedTarget.WingetSource
                    WingetUseId                = $resolvedTarget.WingetUseId
                    SkipWinget                 = $resolvedTarget.SkipWinget
                    DownloadUrl                = $resolvedTarget.DownloadUrl
                    DownloadFileName           = $resolvedTarget.DownloadFileName
                    InstallerArgs              = $resolvedTarget.InstallerArgs
                    InstallKind                = $resolvedTarget.InstallKind
                    AdditionalSuccessExitCodes = @($resolvedTarget.AdditionalSuccessExitCodes)
                    RefreshDownloadOnFailure   = $resolvedTarget.RefreshDownloadOnFailure
                    AllowDirectDownloadFallback = $resolvedTarget.AllowDirectDownloadFallback
                    AddToPath                  = $resolvedTarget.AddToPath
                    PathProbe                  = $resolvedTarget.PathProbe
                }

                $job = Start-Job -ScriptBlock {
                    param(
                        [hashtable]$Target,
                        [string]$HunterRoot,
                        [string]$DownloadDir,
                        [string]$InstallerHelperContent
                    )

                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'
                    $ProgressPreference = 'SilentlyContinue'
                    . ([scriptblock]::Create($InstallerHelperContent))

                    function Add-ResultPathEntry {
                        param(
                            [hashtable]$InstallResult,
                            [string]$PathEntry
                        )

                        if ([string]::IsNullOrWhiteSpace($PathEntry) -or -not (Test-Path $PathEntry)) {
                            return
                        }

                        $existingEntries = @($InstallResult['PathEntries'])
                        if ($existingEntries -contains $PathEntry) {
                            return
                        }

                        $InstallResult['PathEntries'] = @(($existingEntries + $PathEntry) | Select-Object -Unique)
                    }

                    function Install-PortablePackageInternal {
                        param(
                            [string]$PackageName,
                            [string]$Path,
                            [bool]$AddToPath,
                            [hashtable]$InstallResult
                        )

                        $resolvedFile = Resolve-DownloadedFile -Path $Path
                        $toolsRoot = Join-Path $HunterRoot 'Tools'
                        $targetDir = Join-Path $toolsRoot (Get-PackageSlug -PackageName $PackageName)
                        New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
                        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

                        $targetPath = Join-Path $targetDir (Split-Path -Leaf $resolvedFile.Path)
                        Copy-Item -Path $resolvedFile.Path -Destination $targetPath -Force

                        if ($AddToPath) {
                            Add-ResultPathEntry -InstallResult $InstallResult -PathEntry $targetDir
                        }
                    }

                    function Install-ArchivePackageInternal {
                        param(
                            [string]$PackageName,
                            [string]$Path,
                            [bool]$AddToPath,
                            [string]$PathProbe,
                            [hashtable]$InstallResult
                        )

                        $resolvedFile = Resolve-DownloadedFile -Path $Path
                        if ($resolvedFile.Type -ne 'Zip') {
                            throw "$PackageName download is not a ZIP archive (detected type: $($resolvedFile.Type))"
                        }

                        $packagesRoot = Join-Path $HunterRoot 'Packages'
                        $extractDir = Join-Path $packagesRoot (Get-PackageSlug -PackageName $PackageName)
                        New-Item -ItemType Directory -Path $packagesRoot -Force | Out-Null
                        if (Test-Path $extractDir) {
                            Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                        }

                        Expand-Archive -Path $resolvedFile.Path -DestinationPath $extractDir -Force

                        if ($AddToPath -and -not [string]::IsNullOrWhiteSpace($PathProbe)) {
                            $probeMatch = Get-ChildItem -Path $extractDir -Recurse -File -Filter $PathProbe -ErrorAction SilentlyContinue |
                                Select-Object -First 1
                            if ($null -ne $probeMatch) {
                                Add-ResultPathEntry -InstallResult $InstallResult -PathEntry $probeMatch.DirectoryName
                            }
                        }
                    }

                    function Install-InstallerPackageInternal {
                        param(
                            [string]$PackageName,
                            [string]$Path,
                            [string]$InstallerArgs,
                            [int[]]$AdditionalSuccessExitCodes,
                            [bool]$SkipSignatureValidation = $false
                        )

                        $resolvedFile = Resolve-DownloadedFile -Path $Path
                        if (-not $SkipSignatureValidation) {
                            Confirm-InstallerSignature -PackageName $PackageName -Path $resolvedFile.Path | Out-Null
                        }
                        $allowedExitCodes = @((@(0, 3010, 1641) + @($AdditionalSuccessExitCodes)) | Select-Object -Unique)

                        Invoke-DirectInstallerWithMutex -Action {
                            switch ($resolvedFile.Type) {
                                'Exe' {
                                    $process = if ([string]::IsNullOrWhiteSpace($InstallerArgs)) {
                                        Start-Process -FilePath $resolvedFile.Path -Wait -PassThru -ErrorAction Stop
                                    } else {
                                        Start-Process -FilePath $resolvedFile.Path -ArgumentList $InstallerArgs -Wait -PassThru -ErrorAction Stop
                                    }

                                    if ($allowedExitCodes -notcontains $process.ExitCode) {
                                        throw "$PackageName installer exited with code $($process.ExitCode)"
                                    }
                                }

                                'Msi' {
                                    $msiArguments = "/i `"$($resolvedFile.Path)`""
                                    if ([string]::IsNullOrWhiteSpace($InstallerArgs)) {
                                        $msiArguments += ' /qn /norestart'
                                    } else {
                                        $msiArguments += " $InstallerArgs"
                                    }

                                    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru -ErrorAction Stop
                                    if ($allowedExitCodes -notcontains $process.ExitCode) {
                                        throw "$PackageName MSI exited with code $($process.ExitCode)"
                                    }
                                }

                                default {
                                    throw "$PackageName download is not an installer file (detected type: $($resolvedFile.Type))"
                                }
                            }
                        }
                    }

                    function Invoke-DirectInstall {
                        param(
                            [hashtable]$InstallTarget,
                            [string]$FilePath,
                            [hashtable]$InstallResult
                        )

                        $skipSignatureValidation = $false
                        if (($InstallTarget -is [System.Collections.IDictionary] -and $InstallTarget.Contains('SkipSignatureValidation')) -or
                            ($null -ne $InstallTarget.PSObject.Properties['SkipSignatureValidation'])) {
                            $skipSignatureValidation = [bool]$InstallTarget.SkipSignatureValidation
                        }

                        switch ($InstallTarget.InstallKind) {
                            'Installer' {
                                Install-InstallerPackageInternal `
                                    -PackageName $InstallTarget.PackageName `
                                    -Path $FilePath `
                                    -InstallerArgs $InstallTarget.InstallerArgs `
                                    -AdditionalSuccessExitCodes $InstallTarget.AdditionalSuccessExitCodes `
                                    -SkipSignatureValidation $skipSignatureValidation
                            }
                            'Portable' {
                                Install-PortablePackageInternal `
                                    -PackageName $InstallTarget.PackageName `
                                    -Path $FilePath `
                                    -AddToPath $InstallTarget.AddToPath `
                                    -InstallResult $InstallResult
                            }
                            'Archive' {
                                Install-ArchivePackageInternal `
                                    -PackageName $InstallTarget.PackageName `
                                    -Path $FilePath `
                                    -AddToPath $InstallTarget.AddToPath `
                                    -PathProbe $InstallTarget.PathProbe `
                                    -InstallResult $InstallResult
                            }
                        }
                    }

                    $result = @{
                        PackageId = $Target.PackageId
                        PackageName = $Target.PackageName
                        Success = $false
                        Message = ''
                        Skipped = $false
                        PathEntries = @()
                    }

                    try {
                        if (-not $Target.SkipWinget -and -not [string]::IsNullOrWhiteSpace($Target.WingetId)) {
                            $wingetArgs = @('install')
                            if ($Target.ContainsKey('WingetUseId') -and -not [bool]$Target.WingetUseId) {
                                $wingetArgs += $Target.WingetId
                            } else {
                                $wingetArgs += @('--id', $Target.WingetId, '-e')
                            }
                            $wingetArgs += @(
                                '--accept-source-agreements',
                                '--accept-package-agreements',
                                '--disable-interactivity',
                                '--silent'
                            )
                            if (-not [string]::IsNullOrWhiteSpace($Target.WingetSource)) {
                                $wingetArgs += @('--source', $Target.WingetSource)
                            }

                            $wingetExitCode = Invoke-WingetWithMutex -Arguments $wingetArgs
                            if ($wingetExitCode -eq 0) {
                                $result.Success = $true
                                if ([string]::IsNullOrWhiteSpace($Target.WingetSource) -or $Target.WingetSource -eq 'winget') {
                                    $result.Message = "$($Target.PackageName) installed via winget"
                                } else {
                                    $result.Message = "$($Target.PackageName) installed via $($Target.WingetSource)"
                                }
                                return [pscustomobject]$result
                            }

                            if (-not $Target.AllowDirectDownloadFallback) {
                                throw "$($Target.PackageName) install via $($Target.WingetSource) failed with exit code $wingetExitCode"
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($Target.DownloadUrl)) {
                            throw "No download source configured for $($Target.PackageName)"
                        }

                        if (-not (Test-Path $DownloadDir)) {
                            New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
                        }

                        $downloadPath = Join-Path $DownloadDir $Target.DownloadFileName
                        $attemptedRefresh = $false

                        while ($true) {
                            if (-not (Test-Path $downloadPath) -or ((Get-Item -Path $downloadPath -ErrorAction SilentlyContinue).Length -le 0)) {
                                try {
                                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                                } catch { }

                                Invoke-WebRequest -Uri $Target.DownloadUrl -OutFile $downloadPath -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 300 -ErrorAction Stop -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
                            }

                            try {
                                Invoke-DirectInstall -InstallTarget $Target -FilePath $downloadPath -InstallResult $result
                                break
                            } catch {
                                if (-not $Target.RefreshDownloadOnFailure -or $attemptedRefresh) {
                                    throw
                                }

                                $attemptedRefresh = $true
                                Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue
                            }
                        }

                        $result.Success = $true
                        $skipSignatureValidation = $false
                        if (($Target -is [System.Collections.IDictionary] -and $Target.Contains('SkipSignatureValidation')) -or
                            ($null -ne $Target.PSObject.Properties['SkipSignatureValidation'])) {
                            $skipSignatureValidation = [bool]$Target.SkipSignatureValidation
                        }

                        if ($skipSignatureValidation) {
                            $result.Message = "$($Target.PackageName) installed via direct download (signature validation intentionally skipped)"
                        } else {
                            $result.Message = "$($Target.PackageName) installed via direct download"
                        }
                    } catch {
                        $result.Message = $_.Exception.Message
                    }

                    return [pscustomobject]$result
                } -ArgumentList $jobTarget, $script:HunterRoot, $script:DownloadDir, $script:InstallerJobHelperContent

                $script:ParallelInstallJobs += [pscustomobject]@{
                    Job    = $job
                    Target = $resolvedTarget
                    StartedAt = Get-Date
                }
                Write-Log "Started parallel install: $($resolvedTarget.PackageName)" 'INFO'
            }
        } else {
            Write-Log "Parallel installer pipeline already running; continuing without waiting." 'INFO'
        }

        $targets = @($script:ParallelInstallTargets)
        $jobs = @($script:ParallelInstallJobs)
        $resultsByPackageId = $script:ParallelInstallResults

        if ($LaunchOnly) {
            $launchedCount = @($jobs).Count
            $satisfiedCount = @($targets | Where-Object {
                $result = $resultsByPackageId[$_.PackageId]
                $null -ne $result -and $result.Success -and $result.Skipped
            }).Count

            Write-Log "Parallel installer pipeline launched: $launchedCount active job(s), $satisfiedCount already satisfied." 'INFO'
            return $true
        }

        if ($jobs.Count -gt 0) {
            Write-Log "Waiting for $($jobs.Count) background installer job(s) to complete..." 'INFO'

            $pendingJobs = [System.Collections.ArrayList]::new()
            foreach ($jobInfo in $jobs) {
                [void]$pendingJobs.Add($jobInfo)
            }

            $jobWaitDeadline = (Get-Date).AddMinutes(30)
            $heartbeatIntervalSec = 15
            $nextHeartbeatAt = (Get-Date).AddSeconds($heartbeatIntervalSec)
            $timedOutJobs = $false

            while ($pendingJobs.Count -gt 0) {
                if ((Get-Date) -ge $jobWaitDeadline) {
                    $timedOutJobs = $true
                    break
                }

                Wait-Job -Job @($pendingJobs | ForEach-Object { $_.Job }) -Any -Timeout 5 | Out-Null
                $terminalJobs = @($pendingJobs | Where-Object { $_.Job.State -in @('Completed', 'Failed', 'Stopped') })
                if ($terminalJobs.Count -eq 0) {
                    if ((Get-Date) -ge $nextHeartbeatAt) {
                        $runningJobs = @($pendingJobs | Where-Object { $_.Job.State -eq 'Running' })
                        $queuedJobs = @($pendingJobs | Where-Object { $_.Job.State -notin @('Running', 'Completed', 'Failed', 'Stopped') })
                        $activeNames = @($runningJobs | Select-Object -ExpandProperty Target | ForEach-Object { $_.PackageName })
                        $activeSuffix = if ($activeNames.Count -gt 0) {
                            " Active: $($activeNames -join ', ')"
                        } else {
                            ''
                        }
                        Write-Log "Installer finalize progress: $($jobs.Count - $pendingJobs.Count)/$($jobs.Count) complete, $($runningJobs.Count) running, $($queuedJobs.Count) queued.$activeSuffix" 'INFO'
                        $nextHeartbeatAt = (Get-Date).AddSeconds($heartbeatIntervalSec)
                    }

                    continue
                }

                foreach ($jobInfo in $terminalJobs) {
                    $elapsed = Format-ElapsedDuration -Duration ((Get-Date) - $jobInfo.StartedAt)
                    $jobState = $jobInfo.Job.State
                    Write-Log "Installer job finished: $($jobInfo.Target.PackageName) [$jobState] after $elapsed" 'INFO'
                    $jobResult = Receive-ParallelInstallerJobResult -JobInfo $jobInfo -ResultsByPackageId $resultsByPackageId
                    $level = if ($jobResult.Success) { 'SUCCESS' } else { 'ERROR' }
                    Write-Log "Installer finalize result: $($jobInfo.Target.PackageName) - $($jobResult.Message)" $level
                    [void]$pendingJobs.Remove($jobInfo)
                }

                $nextHeartbeatAt = (Get-Date).AddSeconds($heartbeatIntervalSec)
            }

            if ($timedOutJobs -and $pendingJobs.Count -gt 0) {
                $timedOutNames = @($pendingJobs | ForEach-Object { $_.Target.PackageName })
                Write-Log "Installer finalize timed out after 30:00. Collecting partial results for still-running job(s): $($timedOutNames -join ', ')" 'WARN'
            }

            foreach ($jobInfo in @($pendingJobs)) {
                $elapsed = Format-ElapsedDuration -Duration ((Get-Date) - $jobInfo.StartedAt)
                Write-Log "Collecting partial installer result: $($jobInfo.Target.PackageName) after $elapsed" 'INFO'
                $jobResult = Receive-ParallelInstallerJobResult -JobInfo $jobInfo -ResultsByPackageId $resultsByPackageId
                $level = if ($jobResult.Success) { 'SUCCESS' } else { 'ERROR' }
                Write-Log "Installer finalize result: $($jobInfo.Target.PackageName) - $($jobResult.Message)" $level
                [void]$pendingJobs.Remove($jobInfo)
            }
        } else {
            Write-Log 'No active installer jobs found. Finalizing install state from current system state.' 'INFO'
        }

        $script:ParallelInstallJobs = @()

        $successCount = 0
        $failCount = 0
        foreach ($target in $targets) {
            $result = $resultsByPackageId[$target.PackageId]
            if ($null -eq $result) {
                $failCount++
                Write-Log "Package install failed: $($target.PackageName) - Missing result record" 'ERROR'
                continue
            }

            if ($result.Success) {
                $successCount++
                $level = if ($result.Skipped) { 'INFO' } else { 'SUCCESS' }
                Write-Log "Package install completed: $($target.PackageName) - $($result.Message)" $level
            } else {
                $failCount++
                Write-Log "Package install failed: $($target.PackageName) - $($result.Message)" 'ERROR'
            }
        }

        Write-Log "Parallel installs complete: $successCount succeeded, $failCount failed" 'INFO'
        Write-Log "Running post-install hooks..." 'INFO'

        if ($resultsByPackageId.ContainsKey('brave') -and
            $resultsByPackageId['brave'].Success -and
            -not ($script:PostInstallCompletion.ContainsKey('brave') -and [bool]$script:PostInstallCompletion['brave'])) {
            Invoke-BraveDebloat
        }

        if ($resultsByPackageId.ContainsKey('powershell7') -and
            $resultsByPackageId['powershell7'].Success -and
            -not ($script:PostInstallCompletion.ContainsKey('powershell7') -and [bool]$script:PostInstallCompletion['powershell7'])) {
            Invoke-DisablePowerShell7Telemetry
        }

        $resolvedExecutablePaths = Resolve-InstallTargetExecutablePaths -Targets $targets -ResultsByPackageId $resultsByPackageId

        foreach ($target in $targets) {
            $result = $resultsByPackageId[$target.PackageId]
            if ($null -eq $result -or -not $result.Success) {
                continue
            }

            if ($script:PostInstallCompletion.ContainsKey($target.PackageId) -and [bool]$script:PostInstallCompletion[$target.PackageId]) {
                continue
            }

            try {
                $executablePath = if ($target.ContainsKey('ExistingExecutablePath') -and
                    -not [string]::IsNullOrWhiteSpace($target.ExistingExecutablePath) -and
                    (Test-Path $target.ExistingExecutablePath)) {
                    $target.ExistingExecutablePath
                } elseif ($resolvedExecutablePaths.ContainsKey($target.PackageId)) {
                    $resolvedExecutablePaths[$target.PackageId]
                } else {
                    $null
                }
                if ($target.PackageId -eq 'cinebench-r23' -and (Test-IsLegacyHunterCinebenchPath -Path $executablePath)) {
                    throw 'Cinebench R23 is still resolving to the legacy Hunter ZIP payload instead of the Microsoft Store install.'
                }

                $postInstallSuccess = Complete-InstalledApp `
                    -PackageName $target.PackageName `
                    -ExecutablePath $executablePath `
                    -ShortcutName $target.ShortcutName `
                    -PinToTaskbar $target.PinToTaskbar `
                    -TaskbarDisplayPatterns $target.PinPatterns `
                    -PostInstallWindowPatterns $target.PostInstallWindowPatterns `
                    -CreateDesktopShortcut $target.CreateDesktopShortcut

                if (-not $postInstallSuccess) {
                    $failCount++
                    $resultsByPackageId[$target.PackageId].Success = $false
                    $resultsByPackageId[$target.PackageId].Message = 'Post-install verification failed.'
                    $script:PostInstallCompletion[$target.PackageId] = $false
                    Write-Log "Post-install verification failed: $($target.PackageName)" 'ERROR'
                    continue
                }

                $script:PostInstallCompletion[$target.PackageId] = $true
                Write-Log "Post-install complete: $($target.PackageName)" 'INFO'
            } catch {
                $failCount++
                $resultsByPackageId[$target.PackageId].Success = $false
                $resultsByPackageId[$target.PackageId].Message = $_.Exception.Message
                $script:PostInstallCompletion[$target.PackageId] = $false
                Write-Log "Post-install setup failed for $($target.PackageName) : $_" 'ERROR'
            }
        }

        return ($failCount -eq 0)

    } catch {
        Write-Log "Error in Invoke-ParallelInstalls: $_" 'ERROR'
        return $false
    }
}

function Invoke-DisablePowerShell7Telemetry {
    <#
    .SYNOPSIS
    Disables PowerShell 7 telemetry by setting environment variable.
    .DESCRIPTION
    Ref: http://winutil.christitus.com/dev/tweaks/essential-tweaks/powershell7tele/
    #>
    param()

    try {
        Write-Log -Message "Disabling PowerShell 7 telemetry..." -Level 'INFO'

        # Pre-check
        $envValue = [Environment]::GetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', 'Machine')
        if ($envValue -eq '1') {
            Write-Log -Message "PowerShell 7 telemetry already disabled. Skipping." -Level 'INFO'
            return
        }

        [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')

        Write-Log -Message "PowerShell 7 telemetry disabled." -Level 'INFO'
    }
    catch {
        Write-Log -Message "Error in Invoke-DisablePowerShell7Telemetry: $_" -Level 'ERROR'
    }
}

function Invoke-BraveDebloat {
    <#
    .SYNOPSIS
    Disables Brave rewards, wallet, VPN, and AI chat.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/bravedebloat/
    #>
    param()

    try {
        Write-Log -Message "Debloating Brave..." -Level 'INFO'

        $bravePath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
        if ((Test-RegistryValue -Path $bravePath -Name 'BraveRewardsDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveWalletDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveVPNDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveAIChatEnabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveStatsPingEnabled' -ExpectedValue 0)) {
            Write-Log -Message "Brave already debloated. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $bravePath -Name 'BraveRewardsDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveWalletDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveVPNDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveAIChatEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveStatsPingEnabled' -Value 0 -Type 'DWord'

        Write-Log -Message "Brave debloated." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-BraveDebloat: $_" -Level 'ERROR'
        return $false
    }
}

#endregion PHASE 8

# ==============================================================================
# PHASE 8 - EXTERNAL TOOLS
# ==============================================================================

function Invoke-ApplyTcpOptimizerTutorialProfile {
    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log 'Applying TCP Optimizer settings...' 'INFO'

        # Cache active adapters once — avoids 5 redundant WMI/CIM round trips
        # Ref: https://learn.microsoft.com/en-us/powershell/scripting/dev-cross-plat/performance/script-authoring-considerations
        $activeAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })

        # -- General tab settings --
        # MTU 1500 on all adapters
        foreach ($adapter in $activeAdapters) {
            try {
                Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('interface', 'ipv4', 'set', 'subinterface', $adapter.Name, 'mtu=1500', 'store=persistent') | Out-Null
            } catch {
                Write-Log "Failed to set MTU on $($adapter.Name): $_" 'WARN'
            }
        }

        # -- Main TCP settings --
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'autotuninglevel=disabled') | Out-Null
        # Windows Scaling Heuristics: Disabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'heuristics', 'disabled') | Out-Null
        # Congestion Control Provider: CTCP
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'supplemental', 'template=Internet', 'congestionprovider=ctcp') | Out-Null
        # RSS: Enabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'rss=enabled') | Out-Null
        # RSC: Enabled
        foreach ($adapter in $activeAdapters) {
            try {
                Enable-NetAdapterRsc -Name $adapter.Name -ErrorAction Stop
            } catch {
                Write-Log "Failed to enable RSC on $($adapter.Name): $_" 'WARN'
            }
        }
        # ECN: Disabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'ecncapability=disabled') | Out-Null
        # Timestamps: Disabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'timestamps=disabled') | Out-Null
        # Chimney Offload: Disabled (legacy, may fail)
        try {
            Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'chimney=disabled') | Out-Null
        } catch {
            Write-Log "Failed to disable chimney offload (legacy, expected on newer builds): $_" 'WARN'
        }
        # Checksum Offloading: Disabled
        foreach ($adapter in $activeAdapters) {
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName '*Checksum Offload*' -DisplayValue 'Disabled' -ErrorAction Stop
            } catch {
                Write-Log "Failed to set checksum offload advanced property on $($adapter.Name): $_" 'WARN'
            }
            try {
                Set-NetAdapterChecksumOffload -Name $adapter.Name -TcpIPv4 Disabled -TcpIPv6 Disabled -UdpIPv4 Disabled -UdpIPv6 Disabled -ErrorAction Stop
            } catch {
                Write-Log "Failed to disable checksum offload on $($adapter.Name): $_" 'WARN'
            }
        }
        # Large Send Offload (LSO): Disabled
        foreach ($adapter in $activeAdapters) {
            try {
                Set-NetAdapterLso -Name $adapter.Name -V1IPv4Enabled $false -IPv4Enabled $false -IPv6Enabled $false -ErrorAction Stop
            } catch {
                Write-Log "Failed to disable LSO on $($adapter.Name): $_" 'WARN'
            }
        }

        # -- Registry-based TCP settings --
        $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

        # TTL: 64
        Set-RegistryValue -Path $tcpParams -Name 'DefaultTTL' -Value 64 -Type DWord
        # TCP 1323 Timestamps: Disabled (0)
        Set-RegistryValue -Path $tcpParams -Name 'Tcp1323Opts' -Value 0 -Type DWord
        # MaxUserPort: 65534
        Set-RegistryValue -Path $tcpParams -Name 'MaxUserPort' -Value 65534 -Type DWord
        # TcpTimedWaitDelay: 30
        Set-RegistryValue -Path $tcpParams -Name 'TcpTimedWaitDelay' -Value 30 -Type DWord
        # Max SYN Retransmissions: 2
        Set-RegistryValue -Path $tcpParams -Name 'TcpMaxConnectRetransmissions' -Value 2 -Type DWord
        # TcpMaxDataRetransmissions: 5
        Set-RegistryValue -Path $tcpParams -Name 'TcpMaxDataRetransmissions' -Value 5 -Type DWord

        # -- Advanced tab --
        $lanmanParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
        # IRPStackSize / first two boxes: 10
        Set-RegistryValue -Path $lanmanParams -Name 'IRPStackSize' -Value 10 -Type DWord
        Set-RegistryValue -Path $lanmanParams -Name 'SizReqBuf' -Value 10 -Type DWord

        # -- Priorities --
        $priorityCtrl = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'
        Set-RegistryValue -Path $priorityCtrl -Name 'LocalPriority' -Value 4 -Type DWord
        Set-RegistryValue -Path $priorityCtrl -Name 'HostsPriority' -Value 5 -Type DWord
        Set-RegistryValue -Path $priorityCtrl -Name 'DnsPriority' -Value 6 -Type DWord
        Set-RegistryValue -Path $priorityCtrl -Name 'NetbtPriority' -Value 7 -Type DWord

        # -- Retransmission / timeout --
        # Non-SACK RTT Resiliency: Disabled
        Set-RegistryValue -Path $tcpParams -Name 'SackOpts' -Value 1 -Type DWord
        # Initial RTO: 2000
        Set-RegistryValue -Path $tcpParams -Name 'InitialRto' -Value 2000 -Type DWord
        # Minimum RTO: 300
        Set-RegistryValue -Path $tcpParams -Name 'MinRto' -Value 300 -Type DWord

        # -- QoS / Throttling --
        $qosPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
        # NonBestEffortLimit: 0
        Set-RegistryValue -Path $qosPath -Name 'NonBestEffortLimit' -Value 0 -Type DWord
        # QoS Do Not Use NLA: Optimal (undocumented but registry-set)
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\QoS' -Name 'DoNotUseNLA' -Value 1 -Type DWord
        # Network Throttling Index: Disabled (FFFFFFFF = 4294967295)
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF -Type DWord

        # -- Gaming / ACK settings --
        $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        $gamesTaskPath = Join-Path $sysProfile 'Tasks\Games'
        $priorityControlPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
        # System Responsiveness: reserve 10% CPU for low-priority work
        Set-RegistryValue -Path $sysProfile -Name 'SystemResponsiveness' -Value 10 -Type DWord
        # Requested scheduler overrides
        Set-RegistryValue -Path $gamesTaskPath -Name 'Scheduling Category' -Value 'High' -Type String
        Set-RegistryValue -Path $gamesTaskPath -Name 'SFIO Priority' -Value 'High' -Type String
        Set-RegistryValue -Path $gamesTaskPath -Name 'Priority' -Value 6 -Type DWord
        Set-RegistryValue -Path $gamesTaskPath -Name 'GPU Priority' -Value 8 -Type DWord
        Set-RegistryValue -Path $priorityControlPath -Name 'Win32PrioritySeparation' -Value 0x26 -Type DWord
        # TCP ACK Frequency: 1 (Disabled/every packet)
        $tcpIntPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        Get-ChildItem $tcpIntPath -ErrorAction SilentlyContinue | ForEach-Object {
            Set-RegistryValue -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord
            # TCP No Delay: 1 (Enabled)
            Set-RegistryValue -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord
        }
        # TCP DelAck Ticks: Disabled (0)
        Set-RegistryValue -Path $tcpParams -Name 'TcpDelAckTicks' -Value 0 -Type DWord

        # -- Cache / memory / ports --
        $memMgmt = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        # Large System Cache: Enabled (1)
        Set-RegistryValue -Path $memMgmt -Name 'LargeSystemCache' -Value 1 -Type DWord
        # Size: Default (1)
        Set-RegistryValue -Path $memMgmt -Name 'Size' -Value 1 -Type DWord

        Write-Log 'TCP optimization settings applied via registry and netsh' 'SUCCESS'

        # Download and open TCP Optimizer for user verification
        $tcpOptimizerPath = Get-TcpOptimizerDownloadPath
        if (-not (Test-Path $tcpOptimizerPath)) {
            Write-Log 'Downloading TCP Optimizer...' 'INFO'
            Download-File -Url 'https://www.speedguide.net/files/TCPOptimizer.exe' -Destination $tcpOptimizerPath
        }
        Ensure-InstallerHelpersLoaded
        Confirm-InstallerSignature -PackageName 'TCP Optimizer' -Path $tcpOptimizerPath -ExpectedSha256 $script:TcpOptimizerSha256 | Out-Null

        Ensure-DesktopShortcut -ShortcutName 'TCP Optimizer' -TargetPath $tcpOptimizerPath -Description 'TCP Optimizer' | Out-Null
        if ($script:IsAutomationRun) {
            Write-Log 'Automation-safe mode enabled; skipping TCP Optimizer UI launch.' 'INFO'
        } else {
            Write-Log 'Opening TCP Optimizer and continuing without manual confirmation...' 'INFO'
            Start-Process $tcpOptimizerPath
        }
        Write-Log 'TCP Optimizer profile applied.' 'SUCCESS'

    } catch {
        Write-Log "Error applying TCP Optimizer profile: $_" 'ERROR'
        throw
    }
}


function Invoke-ApplyOOSUSilentRecommendedPlusSomewhat {
    <#
    .SYNOPSIS
        Opens O&O ShutUp10 for user-guided privacy and performance optimization.

    .DESCRIPTION
        Downloads and opens O&O ShutUp10 (https://www.oo-software.com/en/shutup10)
        for the user to apply recommended and somewhat recommended privacy/performance
        settings. Targets 170+ privacy-focused settings.
    #>

    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log "Preparing O&O ShutUp10..." 'INFO'

        # Download O&O ShutUp10
        $oosuPath = Get-OOSUDownloadPath
        $oosuConfigPath = Get-OOSUConfigPath
        if (-not (Test-Path $oosuPath)) {
            Write-Log "Downloading O&O ShutUp10..." 'INFO'
            Download-File -Url 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -Destination $oosuPath
        }
        Ensure-InstallerHelpersLoaded
        Confirm-InstallerSignature -PackageName 'O&O ShutUp10' -Path $oosuPath -ExpectedSha256 $script:OOSUSha256 | Out-Null

        Write-Log "Downloading O&O ShutUp10 preset..." 'INFO'
        $forceOOSUConfigRefresh = -not ($script:PrefetchedExternalAssets.ContainsKey('oosu-config') -and [bool]$script:PrefetchedExternalAssets['oosu-config'])
        Download-File -Url $script:OOSUConfigUrl -Destination $oosuConfigPath -Force:$forceOOSUConfigRefresh | Out-Null

        Write-Log "Importing O&O ShutUp10 preset silently..." 'INFO'
        Start-ProcessChecked -FilePath $oosuPath -ArgumentList @($oosuConfigPath, '/quiet', '/force') -WindowStyle Hidden | Out-Null

        Ensure-DesktopShortcut -ShortcutName 'O&O ShutUp10' -TargetPath $oosuPath -Description 'O&O ShutUp10' | Out-Null
        if ($script:IsAutomationRun) {
            Write-Log 'Automation-safe mode enabled; skipping O&O ShutUp10 UI launch.' 'INFO'
        } else {
            Start-Process -FilePath $oosuPath | Out-Null
        }

        Write-Log "O&O ShutUp10 preset imported silently.$(if ($script:IsAutomationRun) { ' UI launch skipped for automation-safe mode.' } else { ' Window opened for review.' })" 'SUCCESS'

    } catch {
        Write-Log "Error applying O&O ShutUp10: $_" 'ERROR'
        throw
    }
}

function Resolve-WallpaperAssetUrl {
    try {
        $sourceUrl = [string]$script:WallpaperSourceUrl
        if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
            throw 'Wallpaper source URL is not configured.'
        }

        if ($sourceUrl -match '^https?://drive\.google\.com/file/d/([A-Za-z0-9_-]+)(/|$)') {
            return "https://drive.google.com/uc?export=download&id=$($Matches[1])"
        }

        if ($sourceUrl -match '^https?://drive\.google\.com/open\?id=([A-Za-z0-9_-]+)(&|$)') {
            return "https://drive.google.com/uc?export=download&id=$($Matches[1])"
        }

        if ($sourceUrl -match '^https?://drive\.google\.com/uc\?') {
            return $sourceUrl
        }

        if ($sourceUrl -match '^https?://[^ ]+\.(jpg|jpeg|png)(\?.*)?$') {
            return $sourceUrl
        }

        if ($sourceUrl -match '^https?://wallhaven\.cc/w/([A-Za-z0-9]+)$') {
            $ProgressPreference = 'SilentlyContinue'
            $wallpaperId = $Matches[1]

            if (-not [string]::IsNullOrWhiteSpace($wallpaperId) -and $wallpaperId.Length -ge 2) {
                $assetPrefix = $wallpaperId.Substring(0, 2)
                foreach ($extension in @('jpg', 'jpeg', 'png')) {
                    $candidateUrl = "https://w.wallhaven.cc/full/$assetPrefix/wallhaven-$wallpaperId.$extension"

                    try {
                        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                        if ($null -ne $curl) {
                            & $curl.Source -I --silent --fail $candidateUrl > $null 2>&1
                            $exitCode = $LASTEXITCODE
                            if ($exitCode -eq 0) {
                                return $candidateUrl
                            }
                        } else {
                            Invoke-WebRequest -Method Head -Uri $candidateUrl -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 30 -ErrorAction Stop | Out-Null
                            return $candidateUrl
                        }
                    } catch {
                        Write-Log "Wallpaper probe failed for ${candidateUrl}: $($_.Exception.Message)" 'WARN'
                    }
                }
            }
        }

        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $page = Invoke-WebRequest -Uri $sourceUrl -Headers $headers -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 60 -ErrorAction Stop
        $html = [string]$page.Content

        foreach ($link in @($page.Links)) {
            $href = [string]$link.href
            if ($href -match '^https?://[^ ]+\.(jpg|jpeg|png)(\?.*)?$') {
                return $Matches[0]
            }
        }

        $patterns = @(
            '<meta[^>]+property=["'']og:image["''][^>]+content=["''](?<url>https://[^"'']+\.(jpg|jpeg|png)(\?[^"'']*)?)["'']',
            '<meta[^>]+content=["''](?<url>https://[^"'']+\.(jpg|jpeg|png)(\?[^"'']*)?)["''][^>]+property=["'']og:image["'']',
            '(?<url>https://[^"'']+\.(jpg|jpeg|png)(\?[^"'']*)?)'
        )

        foreach ($pattern in $patterns) {
            $match = [regex]::Match($html, $pattern)
            if ($match.Success) {
                if ($match.Groups['url'].Success) {
                    return $match.Groups['url'].Value
                }

                return $match.Value
            }
        }

        throw "Could not resolve wallpaper asset from $sourceUrl"
    } catch {
        Write-Log "Failed to resolve wallpaper asset: $_" 'WARN'
        return $null
    }
}

function Set-CurrentUserDesktopWallpaper {
    param([string]$WallpaperPath)

    if (-not ('HunterWallpaperNative' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class HunterWallpaperNative {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(int uiAction, int uiParam, string pvParam, int fWinIni);
}
"@
    }

    $SPI_SETDESKWALLPAPER = 20
    $SPIF_UPDATEINIFILE = 0x01
    $SPIF_SENDCHANGE = 0x02
    $setResult = [HunterWallpaperNative]::SystemParametersInfo(
        $SPI_SETDESKWALLPAPER,
        0,
        $WallpaperPath,
        ($SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE)
    )

    if (-not $setResult) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SystemParametersInfo failed with Win32 error $lastError"
    }
}

function Invoke-ApplyWallpaperEverywhere {
    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log 'Downloading and applying wallpaper to desktop...' 'INFO'

        $wallpaperUrl = Get-ResolvedWallpaperAssetUrl
        if ([string]::IsNullOrWhiteSpace($wallpaperUrl)) {
            Write-Log 'Wallpaper asset could not be resolved. Skipping wallpaper step.' 'WARN'
            return $true
        }

        $wallpaperPath = Get-WallpaperAssetPath -WallpaperUrl $wallpaperUrl
        $forceWallpaperRefresh = -not ($script:PrefetchedExternalAssets.ContainsKey('wallpaper') -and [bool]$script:PrefetchedExternalAssets['wallpaper'])
        Download-File -Url $wallpaperUrl -Destination $wallpaperPath -Force:$forceWallpaperRefresh | Out-Null

        Remove-RegistryValueForAllUsers -SubPath 'Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'Wallpaper'
        Remove-RegistryValueForAllUsers -SubPath 'Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'WallpaperStyle'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name 'LockScreenImage'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name 'NoChangingLockScreen'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'DesktopImagePath'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'DesktopImageUrl'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImagePath'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageUrl'

        Set-CurrentUserDesktopWallpaper -WallpaperPath $wallpaperPath
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'Wallpaper' -Value $wallpaperPath
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'WallpaperStyle' -Value '10'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'TileWallpaper' -Value '0'

        Start-Process -FilePath rundll32.exe -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden | Out-Null
        Request-ExplorerRestart

        Write-Log "Wallpaper applied to desktop without locking future wallpaper changes: $wallpaperPath" 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to apply wallpaper everywhere: $_" 'ERROR'
        return $false
    }
}

function Invoke-OpenAdvancedSystemSettings {
    try {
        if ($script:IsAutomationRun) {
            Write-Log 'Automation-safe mode enabled; skipping classic System Properties UI launch.' 'INFO'
            return $true
        }

        Write-Log 'Opening classic System Properties (Advanced tab)...' 'INFO'

        # Snapshot existing SystemSettings processes so we only kill NEW ones that
        # Windows 11 spawns as a side-effect of launching System Properties dialogs.
        $preExistingSettingsPids = @(
            Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Id
        )

        $spaExe = Join-Path $env:SystemRoot 'System32\SystemPropertiesAdvanced.exe'
        if (Test-Path $spaExe) {
            Start-Process -FilePath $spaExe | Out-Null
            Write-Log 'Launched SystemPropertiesAdvanced.exe' 'SUCCESS'
        } else {
            Start-Process -FilePath 'sysdm.cpl' -ArgumentList ',3' | Out-Null
            Write-Log 'Launched sysdm.cpl directly (SystemPropertiesAdvanced.exe not found)' 'INFO'
        }

        # Windows 11 often opens the native Settings app alongside the classic
        # System Properties dialog. Poll briefly and kill any NEW SystemSettings
        # processes that were not running before the launch.
        for ($poll = 0; $poll -lt 8; $poll++) {
            Start-Sleep -Milliseconds 500
            $newSettingsProcesses = @(
                Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -notin $preExistingSettingsPids }
            )
            foreach ($proc in $newSettingsProcesses) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    Write-Log "Killed unwanted SystemSettings process (PID $($proc.Id)) spawned by Windows 11" 'INFO'
                } catch {
                    Write-Log "Failed to kill SystemSettings PID $($proc.Id): $_" 'WARN'
                }
            }
        }

        return $true
    } catch {
        Write-Log "Failed to open Advanced System Settings: $_" 'ERROR'
        return $false
    }
}

function Invoke-CreateNetworkConnectionsShortcut {
    <#
    .SYNOPSIS
        Creates a Network Connections shortcut, places it in the Start Menu, and pins it.
    #>

    try {
        Write-Log 'Creating Network Connections shortcut...' 'INFO'

        $controlExe = Join-Path $env:SystemRoot 'System32\control.exe'
        $iconDllPath = Join-Path $env:SystemRoot 'System32\netshell.dll'
        $iconLocation = "$iconDllPath,0"
        $shortcutName = 'Network Connections'
        $description = 'View and manage network connections'

        # Create desktop shortcut
        Ensure-DesktopShortcut `
            -ShortcutName $shortcutName `
            -TargetPath $controlExe `
            -Arguments 'ncpa.cpl' `
            -Description $description `
            -IconLocation $iconLocation

        # Create shortcut in All Users Start Menu Programs
        $startMenuShortcutPath = Join-Path $script:AllUsersStartMenuProgramsPath "$shortcutName.lnk"
        New-WindowsShortcut `
            -ShortcutPath $startMenuShortcutPath `
            -TargetPath $controlExe `
            -Arguments 'ncpa.cpl' `
            -Description $description `
            -IconLocation $iconLocation

        # Pin to Start menu via shell verb
        if (Test-Path $startMenuShortcutPath) {
            try {
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.Namespace((Split-Path -Parent $startMenuShortcutPath))
                $item = $folder.ParseName((Split-Path -Leaf $startMenuShortcutPath))
                $pinVerb = $item.Verbs() | Where-Object { $_.Name -match 'Pin to Start|pintostartscreen|Unpin from Start' -and $_.Name -match 'Pin' }
                if ($pinVerb) {
                    $pinVerb.DoIt()
                    Write-Log "Pinned '$shortcutName' to Start menu via shell verb" 'SUCCESS'
                } else {
                    Write-Log "Pin to Start verb not available for '$shortcutName' (may require policy-based pinning)" 'WARN'
                }
            } catch {
                Write-Log "Failed to pin '$shortcutName' to Start menu: $_" 'WARN'
            }
        }

        Write-Log "Network Connections shortcut created and placed in Start Menu" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Failed to create Network Connections shortcut: $_" 'ERROR'
        return $false
    }
}

#=============================================================================
# PHASE 9: CLEANUP
#=============================================================================

function Invoke-DeleteTempFiles {
    <#
    .SYNOPSIS
        Removes temporary files from the standard WinUtil temp directories.

    .DESCRIPTION
        Recursively removes temporary files from the current user's TEMP directory
        and Windows\Temp.

        Reference: https://winutil.christitus.com/dev/tweaks/essential-tweaks/deletetempfiles/
    #>

    try {
        Write-Log "Cleaning temporary files..." 'INFO'

        $tempPaths = @(
            $env:TEMP,
            (Join-Path $script:WindowsRoot 'Temp')
        )

        $totalRemoved = 0
        $totalFailed = 0

        foreach ($path in $tempPaths) {
            if (Test-Path $path) {
                try {
                    $items = @(Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue)
                    $removeErrors = @()
                    $items | Remove-Item -Recurse -Force -ErrorAction Continue -ErrorVariable +removeErrors

                    $failed = @($removeErrors).Count
                    $removed = [Math]::Max(0, $items.Count - $failed)

                    $totalRemoved += $removed
                    $totalFailed += $failed

                    if ($failed -gt 0) {
                        Write-Log "Temporary cleanup removed $removed items from $path and skipped $failed locked or inaccessible item(s)." 'WARN'
                    } else {
                        Write-Log "Cleaned $removed items from $path" 'INFO'
                    }
                } catch {
                    Write-Log "Warning cleaning $path : $_" 'WARN'
                }
            }
        }

        if ($totalFailed -gt 0) {
            Write-Log "Temporary file cleanup completed with warnings: $totalRemoved removed, $totalFailed skipped" 'WARN'
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = "Skipped $totalFailed temporary item(s) that could not be removed"
            }
        }

        Write-Log "Temporary file cleanup complete: $totalRemoved items removed" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error deleting temporary files: $_" 'ERROR'
        return $false
    }
}


function Invoke-RunDiskCleanup {
    <#
    .SYNOPSIS
        Runs the WinUtil disk cleanup sequence.

    .DESCRIPTION
        Mirrors the current WinUtil disk cleanup flow:
        - cleanmgr.exe /d C: /VERYLOWDISK
        - Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase

        Reference: https://winutil.christitus.com/dev/tweaks/essential-tweaks/diskcleanup/
    #>

    try {
        if ($script:IsHyperVGuest) {
            Write-Log 'Hyper-V guest detected, skipping Windows Disk Cleanup and DISM cleanup.' 'INFO'
            return (New-TaskSkipResult -Reason 'Disk cleanup is intentionally skipped on Hyper-V guests')
        }

        Write-Log "Running Windows Disk Cleanup using the WinUtil sequence..." 'INFO'

        Invoke-NativeCommandChecked -FilePath 'cleanmgr.exe' -ArgumentList @('/d', 'C:', '/VERYLOWDISK') | Out-Null
        Invoke-NativeCommandChecked -FilePath 'Dism.exe' -ArgumentList @('/online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') | Out-Null

        Write-Log 'Windows Disk Cleanup sequence completed successfully.' 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error running Disk Cleanup: $_" 'ERROR'
        return $false
    }
}

function Test-TaskHandlerReturnedFailure {
    param(
        [object]$TaskResult,
        [bool]$LoggedError = $false
    )

    if ($TaskResult -is [System.Exception] -or $TaskResult -is [System.Management.Automation.ErrorRecord]) {
        return $true
    }

    if ($LoggedError) {
        return $true
    }

    if ($TaskResult -is [hashtable]) {
        if ($TaskResult.ContainsKey('Success')) {
            return (-not [bool]$TaskResult['Success'])
        }

        if ($TaskResult.ContainsKey('Status')) {
            return ([string]$TaskResult['Status'] -eq 'Failed')
        }
    }

    if ($null -ne $TaskResult -and $TaskResult.PSObject.Properties['Success']) {
        return (-not [bool]$TaskResult.Success)
    }

    if ($null -ne $TaskResult -and $TaskResult.PSObject.Properties['Status']) {
        return ([string]$TaskResult.Status -eq 'Failed')
    }

    if ($TaskResult -is [bool]) {
        return (-not $TaskResult)
    }

    $resultItems = @($TaskResult | Where-Object { $null -ne $_ })
    if ($resultItems.Count -eq 0) {
        return $LoggedError
    }

    $booleanItems = @($resultItems | Where-Object { $_ -is [bool] })
    if ($booleanItems.Count -eq 0) {
        return $LoggedError
    }

    return (-not [bool]$booleanItems[-1])
}


function Invoke-RetryFailedTasks {
    <#
    .SYNOPSIS
        Retries execution of all tasks that previously failed.

    .DESCRIPTION
        Iterates through $script:FailedTasks, re-executes each task's ApplyHandler,
        and moves successfully completed tasks from FailedTasks to CompletedTasks.

    .PARAMETER Tasks
        The full task array to use as reference.
    #>

    param(
        [array]$Tasks = @($script:TaskList)
    )

    try {
        $script:FailedTasks = @($script:FailedTasks)
        $script:CompletedTasks = @($script:CompletedTasks)

        if (@($Tasks).Count -eq 0) {
            Write-Log 'No task list available for retry processing' 'WARN'
            return $false
        }

        if (@($script:FailedTasks).Count -eq 0) {
            Write-Log "No failed tasks to retry" 'INFO'
            return (New-TaskSkipResult -Reason 'No failed tasks required retry')
        }

        Write-Log "Retrying $(@($script:FailedTasks).Count) failed task(s)..." 'INFO'

        $failedTaskIds = @($script:FailedTasks)

        foreach ($taskId in $failedTaskIds) {
            $task = $Tasks | Where-Object { $_.TaskId -eq $taskId }

            if (-not $task) {
                Write-Log "Task $taskId not found in task list" 'WARN'
                continue
            }

            try {
                Write-Log "Retrying task: $taskId" 'INFO'

                $script:CurrentTaskLoggedError = $false
                $script:CurrentTaskLoggedWarning = $false
                $retryResult = & $task.ApplyHandler
                if (Test-TaskHandlerReturnedFailure -TaskResult $retryResult -LoggedError:$script:CurrentTaskLoggedError) {
                    throw "Task handler returned failure for $taskId"
                }

                $retryStatus = Get-TaskHandlerCompletionStatus -TaskResult $retryResult -LoggedWarning:$script:CurrentTaskLoggedWarning

                $script:FailedTasks = @($script:FailedTasks | Where-Object { $_ -ne $taskId })
                if ($retryStatus -ne 'Skipped') {
                    Add-CompletedTask -TaskId $taskId
                }
                $task.Status = $retryStatus
                $task.Error = $null

                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = $retryStatus
                    Error  = $null
                }

                switch ($retryStatus) {
                    'CompletedWithWarnings' { Write-Log "Retry completed with warnings: $taskId" 'WARN' }
                    'Skipped' { Write-Log "Retry skipped: $taskId" 'INFO' }
                    default { Write-Log "Retry succeeded: $taskId" 'SUCCESS' }
                }

            } catch {
                Write-Log "Retry failed for $taskId : $_" 'ERROR'
                $task.Error = $_.Exception.Message
                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = 'Failed'
                    Error  = $task.Error
                }
                # Keep in FailedTasks
            }
        }

        Write-Log "Task retry complete: $(@($script:FailedTasks).Count) still failing" 'INFO'
        return (@($script:FailedTasks).Count -eq 0)

    } catch {
        Write-Log "Error retrying failed tasks: $_" 'ERROR'
        throw
    }
}


function Invoke-ExportDesktopOperationLog {
    <#
    .SYNOPSIS
        Exports a comprehensive operation report to the desktop.

    .DESCRIPTION
        Creates a timestamped report file on the user's desktop containing:
        - Operation summary (total, completed, failed)
        - List of completed tasks
        - List of failed tasks with error details
        - Reboot status
        - Also copies the full log file to the desktop
    #>

    try {
        Write-Log "Exporting operation report to desktop..." 'INFO'

        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportPath = Join-Path $desktopPath "Hunter-Report-$timestamp.txt"
        $completedTasks = @()
        $warningTasks = @()
        $skippedTasks = @()
        $failedTasks = @()

        if ($script:TaskResults.Count -gt 0) {
            foreach ($entry in @($script:TaskResults.GetEnumerator() | Sort-Object Name)) {
                switch ([string]$entry.Value.Status) {
                    'Completed' { $completedTasks += $entry.Name }
                    'CompletedWithWarnings' { $warningTasks += $entry.Name }
                    'Skipped' { $skippedTasks += $entry.Name }
                    'Failed' { $failedTasks += $entry.Name }
                }
            }
        } else {
            $completedTasks = @($script:CompletedTasks)
            $failedTasks = @($script:FailedTasks)
        }

        # Gather statistics
        $totalTasks = $completedTasks.Count + $warningTasks.Count + $skippedTasks.Count + $failedTasks.Count
        $completedCount = $completedTasks.Count
        $warningCount = $warningTasks.Count
        $skippedCount = $skippedTasks.Count
        $failedCount = $failedTasks.Count

        # Check for pending reboot
        $rebootPending = Test-PendingReboot

        # Build report content
        $elapsedTime = if ($null -ne $script:RunStopwatch) { Format-ElapsedDuration $script:RunStopwatch.Elapsed } else { 'N/A' }
        $reportContent = @(
            "========================================",
            "        HUNTER OPERATION REPORT",
            "========================================",
            "",
            "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "Computer: $env:COMPUTERNAME",
            "User: $env:USERNAME",
            "",
            '---- SUMMARY ----',
            "Elapsed Time:     $elapsedTime",
            "Total Tasks:      $totalTasks",
            "Completed:        $completedCount",
            "Warnings:         $warningCount",
            "Skipped:          $skippedCount",
            "Failed:           $failedCount",
            "Success Rate:     $([math]::Round(($completedCount / [math]::Max($totalTasks, 1)) * 100, 1))%",
            "",
            "Pending Reboot:   $(if ($null -eq $rebootPending) { 'UNKNOWN (check failed)' } elseif ($rebootPending) { 'YES' } else { 'NO' })",
            ""
        )

        # Add completed tasks
        if ($completedTasks.Count -gt 0) {
            $reportContent += @(
                '---- COMPLETED TASKS ----'
            )
            $reportContent += $completedTasks | ForEach-Object { "  [+] $_" }
            $reportContent += @(
                ""
            )
        }

        if ($warningTasks.Count -gt 0) {
            $reportContent += @(
                '---- COMPLETED WITH WARNINGS ----'
            )

            foreach ($warningTaskId in $warningTasks) {
                $reportContent += "  [!] $warningTaskId"
                if ($script:TaskResults.ContainsKey($warningTaskId)) {
                    $result = $script:TaskResults[$warningTaskId]
                    if ($result.Error) {
                        $reportContent += "    Detail: $($result.Error)"
                    }
                }
            }

            $reportContent += ""
        }

        if ($skippedTasks.Count -gt 0) {
            $reportContent += @(
                '---- SKIPPED TASKS ----'
            )
            $reportContent += $skippedTasks | ForEach-Object { "  [-] $_" }
            $reportContent += @(
                ""
            )
        }

        # Add failed tasks
        if ($failedTasks.Count -gt 0) {
            $reportContent += @(
                '---- FAILED TASKS ----'
            )

            foreach ($failedTaskId in $failedTasks) {
                $reportContent += "  [X] $failedTaskId"

                if ($script:TaskResults.ContainsKey($failedTaskId)) {
                    $result = $script:TaskResults[$failedTaskId]
                    if ($result.Error) {
                        $reportContent += "    Error: $($result.Error)"
                    }
                }
            }

            $reportContent += ""
        }

        if (@($script:RunInfrastructureIssues).Count -gt 0) {
            $reportContent += @(
                '---- INFRASTRUCTURE ISSUES ----'
            )
            $reportContent += @($script:RunInfrastructureIssues | ForEach-Object { "  [!] $_" })
            $reportContent += @(
                ""
            )
        }

        $reportContent += @(
            "========================================",
            "Report generated by Hunter v2.0",
            "========================================",
            ""
        )

        # Write report
        $reportContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force

        Write-Log "Report exported to: $reportPath" 'SUCCESS'

        # Copy main log file to desktop
        if (Test-Path $script:LogPath) {
            $logDesktopPath = Join-Path $desktopPath "Hunter-Full-Log-$timestamp.txt"
            Copy-Item -Path $script:LogPath -Destination $logDesktopPath -Force
            Write-Log "Full log copied to: $logDesktopPath" 'SUCCESS'
        }

        Write-Log "Desktop operation log export complete" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error exporting operation log: $_" 'ERROR'
        return $false
    }
}

#=============================================================================
# TASK ENGINE
#=============================================================================

function New-Task {
    <#
    .SYNOPSIS
        Creates a new task object for the Hunter execution engine.

    .PARAMETER TaskId
        Unique identifier for the task (e.g., 'core-dark-mode')

    .PARAMETER Phase
        Phase number indicating execution order

    .PARAMETER ApplyHandler
        ScriptBlock that executes the task's main logic

    .PARAMETER Description
        Human-readable description of what the task does
    #>

    param(
        [string]$TaskId,
        [string]$Phase,
        [scriptblock]$ApplyHandler,
        [string]$Description = ''
    )

    return @{
        TaskId       = $TaskId
        Phase        = $Phase
        ApplyHandler = $ApplyHandler
        Description  = $Description
        Status       = 'Pending'
        Error        = $null
    }
}


function Invoke-TaskExecution {
    <#
    .SYNOPSIS
        Executes all tasks in order, with checkpoint recovery.

    .DESCRIPTION
        Iterates through each task, checking if already completed (via checkpoint),
        then executing the ApplyHandler. Handles success/failure logging and progress
        updates. Maintains task results for reporting.

    .PARAMETER Tasks
        Array of task objects created by Build-Tasks
    #>

    param(
        [array]$Tasks
    )

    try {
        Write-Log "Starting task execution engine..." 'INFO'

        foreach ($task in $Tasks) {
            try {
                # Check if already completed
                if (Test-TaskCompleted -TaskId $task.TaskId) {
                    Write-Log "Task already completed (checkpoint): $($task.TaskId)" 'INFO'
                    $task.Status = 'Completed'
                    if (-not $script:TaskResults) {
                        $script:TaskResults = @{}
                    }
                    $script:TaskResults[$task.TaskId] = @{
                        Status = 'Completed'
                        Error  = $null
                    }
                    Update-ProgressState -Tasks $Tasks
                    continue
                }

                # Update status and progress
                $task.Status = 'Running'
                Update-ProgressState -Tasks $Tasks

                Write-Log "Executing task: $($task.TaskId) [Phase $($task.Phase)]" 'INFO'

                $script:CurrentTaskLoggedError = $false
                $script:CurrentTaskLoggedWarning = $false
                $taskResult = & $task.ApplyHandler
                if (Test-TaskHandlerReturnedFailure -TaskResult $taskResult -LoggedError:$script:CurrentTaskLoggedError) {
                    throw "Task handler returned failure for $($task.TaskId)"
                }

                $taskStatus = Get-TaskHandlerCompletionStatus -TaskResult $taskResult -LoggedWarning:$script:CurrentTaskLoggedWarning
                $task.Status = $taskStatus
                $task.Error = $null
                if ($taskStatus -ne 'Skipped') {
                    Add-CompletedTask -TaskId $task.TaskId
                }

                switch ($taskStatus) {
                    'CompletedWithWarnings' { Write-Log "Task completed with warnings: $($task.TaskId)" 'WARN' }
                    'Skipped' { Write-Log "Task skipped: $($task.TaskId)" 'INFO' }
                    default { Write-Log "Task completed: $($task.TaskId)" 'SUCCESS' }
                }

                # Store result
                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = $taskStatus
                    Error  = $null
                }

            } catch {
                # Failure
                $task.Status = 'Failed'
                $task.Error = $_.Exception.Message

                if (-not $script:FailedTasks) {
                    $script:FailedTasks = @()
                }
                if ($script:FailedTasks -notcontains $task.TaskId) {
                    $script:FailedTasks = @($script:FailedTasks) + @($task.TaskId)
                }

                Write-Log "Task failed: $($task.TaskId) - $($task.Error)" 'ERROR'

                # Store result
                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = 'Failed'
                    Error  = $task.Error
                }

                # Strict mode: abort on any task failure
                if ($script:StrictMode) {
                    Write-Log "STRICT MODE: Aborting run due to task failure: $($task.TaskId)" 'ERROR'
                    throw "Strict mode abort: task '$($task.TaskId)' failed - $($task.Error)"
                }
            } finally {
                Invoke-CollectCompletedParallelInstallJobs
                Invoke-CollectCompletedExternalAssetPrefetchJobs
                # Always update progress
                Update-ProgressState -Tasks $Tasks
                Save-Checkpoint
            }
        }

        if (@($script:FailedTasks).Count -gt 0) {
            Write-Log "Task execution engine complete with $(@($script:FailedTasks).Count) failed task(s)" 'WARN'
        } else {
            Write-Log "Task execution engine complete" 'SUCCESS'
        }

    } catch {
        Write-Log "Critical error in task execution engine: $_" 'ERROR'
        throw
    }
}

#=============================================================================
# BUILD-TASKS
#=============================================================================

function Build-Tasks {
    <#
    .SYNOPSIS
        Builds and returns the complete ordered task list for Hunter execution.

    .DESCRIPTION
        Constructs all tasks across 9 phases in proper execution order.
        Each task references an Invoke-* function from Parts A, B, or C.
        Tasks are organized by phase for logical dependency management.

    .OUTPUTS
        [array] Ordered task array suitable for Invoke-TaskExecution
    #>

    $tasks = @()

    # -------------------------------------------------------------------------
    # PHASE 1: PREFLIGHT
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'preflight-internet' `
        -Phase '1' `
        -ApplyHandler { Invoke-VerifyInternetConnectivity } `
        -Description 'Verify internet connectivity'

    $tasks += New-Task `
        -TaskId 'preflight-restore-point' `
        -Phase '1' `
        -ApplyHandler { Invoke-CreateRestorePoint } `
        -Description 'Create Windows System Restore point'

    $tasks += New-Task `
        -TaskId 'preflight-predownload-v2' `
        -Phase '1' `
        -ApplyHandler { Invoke-PreDownloadInstallers } `
        -Description 'Start background package downloads and installs'

    $tasks += New-Task `
        -TaskId 'install-launch-packages-v2' `
        -Phase '2' `
        -ApplyHandler { Invoke-ParallelInstalls -LaunchOnly } `
        -Description 'Ensure package installers are running in parallel'

    # -------------------------------------------------------------------------
    # PHASE 2: CORE
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'core-local-user-v2' `
        -Phase '2' `
        -ApplyHandler { Invoke-EnsureLocalStandardUser } `
        -Description 'Ensure standard local user exists'

    $tasks += New-Task `
        -TaskId 'core-autologin-v2' `
        -Phase '2' `
        -ApplyHandler { Invoke-ConfigureAutologin } `
        -Description 'Configure autologin for standard user'

    $tasks += New-Task `
        -TaskId 'core-dark-mode' `
        -Phase '2' `
        -ApplyHandler { Invoke-EnableDarkMode } `
        -Description 'Enable Windows dark mode theme'

    $tasks += New-Task `
        -TaskId 'core-ultimate-performance' `
        -Phase '2' `
        -ApplyHandler { Invoke-ActivateUltimatePerformance } `
        -Description 'Activate Ultimate Performance power plan'

    # -------------------------------------------------------------------------
    # PHASE 3: START/UI
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'startui-bing-search' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableBingStartSearch } `
        -Description 'Disable Bing search in Start Menu'

    $tasks += New-Task `
        -TaskId 'startui-start-recommendations-v4' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableStartRecommendations } `
        -Description 'Disable Start Menu recommendations'

    $tasks += New-Task `
        -TaskId 'startui-search-box' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableTaskbarSearchBox } `
        -Description 'Disable taskbar search box'

    $tasks += New-Task `
        -TaskId 'startui-task-view' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableTaskViewButton } `
        -Description 'Disable Task View button'

    $tasks += New-Task `
        -TaskId 'startui-widgets' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableWidgets } `
        -Description 'Disable Windows Widgets'

    $tasks += New-Task `
        -TaskId 'startui-end-task' `
        -Phase '3' `
        -ApplyHandler { Invoke-EnableEndTaskOnTaskbar } `
        -Description 'Enable End Task option on taskbar'

    $tasks += New-Task `
        -TaskId 'startui-notifications' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableNotificationsTrayCalendar } `
        -Description 'Disable notifications, tray, and calendar'

    $tasks += New-Task `
        -TaskId 'startui-new-outlook' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableNewOutlook } `
        -Description 'Disable new Outlook and auto-migration'

    $tasks += New-Task `
        -TaskId 'startui-settings-home' `
        -Phase '3' `
        -ApplyHandler { Invoke-HideSettingsHome } `
        -Description 'Hide Settings home page'

    # -------------------------------------------------------------------------
    # PHASE 4: EXPLORER
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'explorer-home-thispc' `
        -Phase '4' `
        -ApplyHandler { Invoke-SetExplorerHomeThisPC } `
        -Description 'Set Explorer home to This PC'

    $tasks += New-Task `
        -TaskId 'explorer-remove-home-v2' `
        -Phase '4' `
        -ApplyHandler { Invoke-RemoveExplorerHomeTab } `
        -Description 'Remove Home tab from Explorer'

    $tasks += New-Task `
        -TaskId 'explorer-remove-gallery-v2' `
        -Phase '4' `
        -ApplyHandler { Invoke-RemoveExplorerGalleryTab } `
        -Description 'Remove Gallery tab from Explorer'

    $tasks += New-Task `
        -TaskId 'explorer-remove-onedrive' `
        -Phase '4' `
        -ApplyHandler { Invoke-RemoveExplorerOneDriveTab } `
        -Description 'Remove OneDrive tab from Explorer'

    $tasks += New-Task `
        -TaskId 'explorer-auto-discovery' `
        -Phase '4' `
        -ApplyHandler { Invoke-DisableExplorerAutoFolderDiscovery } `
        -Description 'Disable Explorer automatic folder discovery'

    # -------------------------------------------------------------------------
    # PHASE 5: MICROSOFT CLOUD
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'cloud-edge-remove' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveEdgeKeepWebView2 } `
        -Description 'Remove Microsoft Edge'

    $tasks += New-Task `
        -TaskId 'cloud-edge-pins' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveEdgePinsAndShortcuts } `
        -Description 'Remove Edge pins and shortcuts'

    $tasks += New-Task `
        -TaskId 'cloud-onedrive-remove' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveOneDrive } `
        -Description 'Remove Microsoft OneDrive'

    $tasks += New-Task `
        -TaskId 'cloud-onedrive-backup' `
        -Phase '5' `
        -ApplyHandler { Invoke-DisableOneDriveFolderBackup } `
        -Description 'Disable OneDrive folder backup'

    $tasks += New-Task `
        -TaskId 'cloud-copilot-remove' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveCopilot } `
        -Description 'Remove Copilot AI assistant'

    # -------------------------------------------------------------------------
    # PHASE 6: REMOVE APPS
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'apps-consumer-features' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableConsumerFeatures } `
        -Description 'Disable consumer experience features'

    $tasks += New-Task `
        -TaskId 'apps-nuke-block' `
        -Phase '6' `
        -ApplyHandler { Invoke-NukeBlockApps } `
        -Description 'Remove and block bloatware apps'

    $tasks += New-Task `
        -TaskId 'apps-inking-typing' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableInkingTyping } `
        -Description 'Disable Inking and Typing data collection'

    $tasks += New-Task `
        -TaskId 'apps-delivery-opt' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableDeliveryOptimization } `
        -Description 'Disable Delivery Optimization'

    $tasks += New-Task `
        -TaskId 'apps-activity-history' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableActivityHistory } `
        -Description 'Disable activity history tracking'

    # -------------------------------------------------------------------------
    # PHASE 7: TWEAKS
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'tweaks-services' `
        -Phase '7' `
        -ApplyHandler { Invoke-SetServiceProfileManual } `
        -Description 'Set service startup profiles to manual'

    $tasks += New-Task `
        -TaskId 'tweaks-virtualization-security' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableVirtualizationSecurityOverhead } `
        -Description 'Disable HVCI, Hyper-V side features, Sandbox, and Application Guard'

    $tasks += New-Task `
        -TaskId 'tweaks-telemetry' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableTelemetry } `
        -Description 'Disable Windows telemetry services'

    $tasks += New-Task `
        -TaskId 'tweaks-location' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableLocationTracking } `
        -Description 'Disable location tracking'

    $tasks += New-Task `
        -TaskId 'tweaks-hibernation' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableHibernation } `
        -Description 'Disable hibernation mode'

    $tasks += New-Task `
        -TaskId 'tweaks-background-apps' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableBackgroundApps } `
        -Description 'Disable unnecessary background apps'

    $tasks += New-Task `
        -TaskId 'tweaks-teredo' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableTeredo } `
        -Description 'Disable Teredo tunneling protocol'

    $tasks += New-Task `
        -TaskId 'tweaks-fso' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableFullscreenOptimizations } `
        -Description 'Disable fullscreen optimizations'

    $tasks += New-Task `
        -TaskId 'tweaks-graphics-scheduling' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyGraphicsSchedulingTweaks } `
        -Description 'Apply HAGS, VRR, Game Bar, Auto HDR, and TDR graphics tweaks'

    $tasks += New-Task `
        -TaskId 'tweaks-dwm-frame-interval' `
        -Phase '7' `
        -ApplyHandler { Invoke-SetDwmFrameInterval } `
        -Description 'Set DWM frame interval to 15'

    $tasks += New-Task `
        -TaskId 'tweaks-ui-desktop' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyUiDesktopPerformanceTweaks } `
        -Description 'Reduce transparency, animations, and desktop compositor overhead'

    $tasks += New-Task `
        -TaskId 'tweaks-razer' `
        -Phase '7' `
        -ApplyHandler { Invoke-BlockRazerSoftware } `
        -Description 'Block Razer software network access'

    $tasks += New-Task `
        -TaskId 'tweaks-adobe' `
        -Phase '7' `
        -ApplyHandler { Invoke-BlockAdobeNetworkTraffic } `
        -Description 'Block Adobe software network traffic'

    $tasks += New-Task `
        -TaskId 'tweaks-power-tuning' `
        -Phase '7' `
        -ApplyHandler { Invoke-ExhaustivePowerTuning } `
        -Description 'Exhaustive power tuning (throttling, fast boot, core parking, device PM)'

    $tasks += New-Task `
        -TaskId 'tweaks-memory-disk' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyMemoryDiskBehaviorTweaks } `
        -Description 'Disable prefetch, RAM compression, Storage Sense, and NTFS last access updates'

    $tasks += New-Task `
        -TaskId 'tweaks-input-maintenance' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyInputAndMaintenanceTweaks } `
        -Description 'Disable mouse acceleration, HPET override, dynamic ticks, and maintenance tasks'

    $tasks += New-Task `
        -TaskId 'tweaks-timer-resolution' `
        -Phase '7' `
        -ApplyHandler { Invoke-InstallTimerResolutionService } `
        -Description 'Install 0.5ms timer resolution service'

    $tasks += New-Task `
        -TaskId 'tweaks-store-search' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableStoreSearch } `
        -Description 'Disable Microsoft Store search results'

    $tasks += New-Task `
        -TaskId 'tweaks-ipv6' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableIPv6 } `
        -Description 'Disable IPv6 on all adapters'

    # -------------------------------------------------------------------------
    # PHASE 8: EXTERNAL TOOLS
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'external-wallpaper-v3' `
        -Phase '8' `
        -ApplyHandler { Invoke-ApplyWallpaperEverywhere } `
        -Description 'Apply wallpaper to desktop'

    $tasks += New-Task `
        -TaskId 'external-tcp-optimizer' `
        -Phase '8' `
        -ApplyHandler { Invoke-ApplyTcpOptimizerTutorialProfile } `
        -Description 'Apply TCP optimizations and verify with TCP Optimizer'

    $tasks += New-Task `
        -TaskId 'external-oosu' `
        -Phase '8' `
        -ApplyHandler { Invoke-ApplyOOSUSilentRecommendedPlusSomewhat } `
        -Description 'Configure privacy with O&O ShutUp10'

    $tasks += New-Task `
        -TaskId 'external-system-properties' `
        -Phase '8' `
        -ApplyHandler { Invoke-OpenAdvancedSystemSettings } `
        -Description 'Open Advanced System Settings'

    $tasks += New-Task `
        -TaskId 'external-network-connections-shortcut' `
        -Phase '8' `
        -ApplyHandler { Invoke-CreateNetworkConnectionsShortcut } `
        -Description 'Create Network Connections shortcut and pin to Start'

    # -------------------------------------------------------------------------
    # PHASE 9: CLEANUP
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'install-finalize-packages-v2' `
        -Phase '9' `
        -ApplyHandler { Invoke-ParallelInstalls } `
        -Description 'Finalize background package installations'

    $tasks += New-Task `
        -TaskId 'cleanup-temp-files' `
        -Phase '9' `
        -ApplyHandler { Invoke-DeleteTempFiles } `
        -Description 'Clean temporary files'

    $tasks += New-Task `
        -TaskId 'cleanup-retry-failed' `
        -Phase '9' `
        -ApplyHandler { Invoke-RetryFailedTasks } `
        -Description 'Retry any failed tasks'

    $tasks += New-Task `
        -TaskId 'cleanup-disk-cleanup' `
        -Phase '9' `
        -ApplyHandler { Invoke-RunDiskCleanup } `
        -Description 'Run Windows Disk Cleanup'

    $tasks += New-Task `
        -TaskId 'cleanup-explorer-restart' `
        -Phase '9' `
        -ApplyHandler { Invoke-DeferredExplorerRestart } `
        -Description 'Restart Explorer with pending changes'

    $tasks += New-Task `
        -TaskId 'cleanup-export-log' `
        -Phase '9' `
        -ApplyHandler { Invoke-ExportDesktopOperationLog } `
        -Description 'Export operation report to desktop'

    return $tasks
}

#=============================================================================
# RESUME TASK SUPPORT
#=============================================================================

function Register-ResumeTask {
    <#
    .SYNOPSIS
        Registers a Windows scheduled task for Hunter resume on logon.

    .DESCRIPTION
        Creates a scheduled task named 'Hunter-Resume' that automatically runs
        the script with -Mode Resume on system logon, enabling recovery from
        mid-operation reboots.
    #>

    try {
        if ($script:IsAutomationRun) {
            Write-Log "Automation-safe mode enabled; skipping resume task registration." 'INFO'
            return
        }

        $scriptPath = $MyInvocation.ScriptName
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }

        if (-not $scriptPath) {
            if (-not [string]::IsNullOrWhiteSpace($script:SelfScriptContent)) {
                Ensure-Directory (Split-Path -Parent $script:ResumeScriptPath)
                Set-Content -Path $script:ResumeScriptPath -Value $script:SelfScriptContent -Force
                $scriptPath = $script:ResumeScriptPath
            } else {
                throw "Could not determine script path for resume task registration."
            }
        }

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Resume"

        $trigger = New-ScheduledTaskTrigger -AtLogOn

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        $principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest

        Register-ScheduledTask `
            -TaskName 'Hunter-Resume' `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Force | Out-Null

        Write-Log "Resume scheduled task registered: Hunter-Resume" 'SUCCESS'

    } catch {
        Write-Log "Error registering resume task: $_" 'ERROR'
        throw
    }
}


function Unregister-ResumeTask {
    <#
    .SYNOPSIS
        Removes the Hunter resume scheduled task.

    .DESCRIPTION
        Deletes the 'Hunter-Resume' scheduled task when script execution
        completes successfully (no pending reboot needed).
    #>

    try {
        if ($script:IsAutomationRun) {
            Write-Log "Automation-safe mode enabled; skipping resume task cleanup." 'INFO'
            return
        }

        $existingTask = Get-ScheduledTask -TaskName 'Hunter-Resume' -ErrorAction SilentlyContinue
        if ($null -eq $existingTask) {
            Write-Log "Resume scheduled task was already absent" 'INFO'
            return $true
        }

        Unregister-ScheduledTask -TaskName 'Hunter-Resume' `
            -Confirm:$false `
            -ErrorAction Stop

        $remainingTask = Get-ScheduledTask -TaskName 'Hunter-Resume' -ErrorAction SilentlyContinue
        if ($null -ne $remainingTask) {
            Add-RunInfrastructureIssue -Message 'Hunter-Resume scheduled task still exists after cleanup was requested.' -Level 'ERROR'
            return $false
        }

        Write-Log "Resume scheduled task unregistered" 'INFO'
        return $true

    } catch {
        Add-RunInfrastructureIssue -Message "Error unregistering resume task: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}


function Test-PendingReboot {
    <#
    .SYNOPSIS
        Detects if Windows has a pending reboot.

    .DESCRIPTION
        Checks Windows registry for pending reboot indicators:
        - RebootPending in Component Based Servicing
        - RebootRequired in Windows Update

    .OUTPUTS
        [bool] $true if reboot is pending, $false otherwise
    #>

    try {
        $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wuau = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

        return ($cbs -or $wuau)

    } catch {
        $script:PendingRebootCheckFailed = $true
        Add-RunInfrastructureIssue -Message "Failed to determine whether Windows is pending reboot: $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
}

#=============================================================================
# MAIN ENTRY POINT
#=============================================================================

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
    #>

    param(
        [ValidateSet('Execute', 'Resume')]
        [string]$Mode = 'Execute',

        [switch]$Strict,

        [switch]$AutomationSafe
    )

    $script:StrictMode = [bool]$Strict

    # Start the run stopwatch immediately — this is the very first executable line
    $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # --------------------------------------------------------------------
        # INITIALIZATION
        # --------------------------------------------------------------------

        # Suppress Invoke-WebRequest progress bars — PS5 renders a UI progress bar
        # that slows downloads up to 10x. Ref: https://github.com/PowerShell/PowerShell/issues/2138
        $ProgressPreference = 'SilentlyContinue'

        # Ensure directories exist
        Ensure-Directory $script:HunterRoot
        Ensure-Directory $script:DownloadDir
        $script:IsAutomationRun = [bool]$AutomationSafe -or $env:GITHUB_ACTIONS -eq 'true' -or $env:HUNTER_AUTOMATION_SAFE -eq '1'

        Write-Log "===========================================================" 'INFO'
        Write-Log '              HUNTER v2.0 - Windows Debloater' 'INFO'
        Write-Log "===========================================================" 'INFO'
        Write-Log ""
        Write-Log "Execution Mode:  $Mode" 'INFO'
        Write-Log "OS Version:      $([System.Environment]::OSVersion.VersionString)" 'INFO'
        Write-Log "User:            $env:USERNAME on $env:COMPUTERNAME" 'INFO'
        Write-Log "Timestamp:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 'INFO'
        Write-Log "Automation:      $(if ($script:IsAutomationRun) { 'YES' } else { 'NO' })" 'INFO'
        Write-Log ""

        # Log administrator status (#Requires -RunAsAdministrator already enforces elevation)
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Log "Administrator:   $(if ($isAdmin) { 'YES' } else { 'NO' })" 'INFO'

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
        Load-Checkpoint

        # --------------------------------------------------------------------
        # BUILD & PREPARE TASKS
        # --------------------------------------------------------------------

        Write-Log "Building task list..." 'INFO'
        $tasks = Build-Tasks
        $script:TaskList = @($tasks)
        Write-Log "Task list built: $($tasks.Count) total tasks" 'SUCCESS'

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

        Write-Log "Registering resume recovery task..." 'INFO'
        Register-ResumeTask

        Write-Log ""
        Write-Log '==== EXECUTION BEGINNING ====' 'INFO'
        Write-Log ""

        # --------------------------------------------------------------------
        # EXECUTE ALL TASKS
        # --------------------------------------------------------------------

        Invoke-TaskExecution -Tasks $tasks

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
        Save-Checkpoint
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
                Write-Log "Pending reboot detected - system will restart in 5 seconds..." 'WARN'
                Write-Log ""
                Start-Sleep -Seconds 5
                Start-Process -FilePath shutdown.exe -ArgumentList '/r', '/t', '0', '/f' -WindowStyle Hidden
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
}

# Override log path if provided
if (-not [string]::IsNullOrWhiteSpace($scriptLogPath)) {
    $script:LogPath = $scriptLogPath
}

# Invoke main orchestrator
Invoke-Main -Mode $scriptMode -Strict:$scriptStrict -AutomationSafe:$scriptAutomationSafe
