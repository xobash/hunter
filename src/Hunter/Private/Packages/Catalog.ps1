function Resolve-HunterInstallTool {
    param([Parameter(Mandatory)][string]$ToolName)

    $tool = Get-HunterTool -Name $ToolName
    if ($null -eq $tool) {
        throw "Hunter tool registration was not found for '$ToolName'."
    }

    return $tool
}

function Get-InstallTargetCatalog {
    return @(
        @{
            ToolName                  = 'PowerShell7'
            PackageId                 = 'powershell7'
            PackageName               = 'PowerShell 7'
            WingetId                  = 'Microsoft.PowerShell'
            ChocolateyId              = 'powershell-core'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'PowerShell7' -Property 'DownloadSpec')
            InstallerArgs             = '/qn /norestart'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'PowerShell7' -Property 'ExecutablePath')
            ShortcutName              = 'PowerShell 7'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*PowerShell*', '*pwsh*')
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'Brave'
            PackageId                 = 'brave'
            PackageName               = 'Brave'
            WingetId                  = 'Brave.Brave'
            ChocolateyId              = 'brave'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'Brave' -Property 'DownloadSpec')
            InstallerArgs             = '/silent /install'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'Brave' -Property 'ExecutablePath')
            ShortcutName              = 'Brave Browser'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*Brave*')
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'Parsec'
            PackageId                 = 'parsec'
            PackageName               = 'Parsec'
            WingetId                  = 'Parsec.Parsec'
            SkipWinget                = $true
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'Parsec' -Property 'DownloadSpec')
            InstallerArgs             = '/silent /norun /percomputer'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @(13)
            RefreshDownloadOnFailure  = $false
            AllowDirectDownloadFallback = $true
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'Parsec' -Property 'ExecutablePath')
            VerificationTimeoutSeconds = 180
            ShortcutName              = 'Parsec'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*Parsec*')
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'Steam'
            PackageId                 = 'steam'
            PackageName               = 'Steam'
            WingetId                  = 'Valve.Steam'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'Steam' -Property 'DownloadSpec')
            InstallerArgs             = '/S'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'Steam' -Property 'ExecutablePath')
            ShortcutName              = 'Steam'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $true
            PinPatterns               = @('*Steam*')
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'FFmpeg'
            PackageId                 = 'ffmpeg'
            PackageName               = 'FFmpeg'
            WingetId                  = 'Gyan.FFmpeg'
            ChocolateyId              = 'ffmpeg'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'FFmpeg' -Property 'DownloadSpec')
            InstallerArgs             = ''
            InstallKind               = 'Archive'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $true
            PathProbe                 = 'ffmpeg.exe'
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'FFmpeg' -Property 'ExecutablePath')
            ShortcutName              = 'FFmpeg'
            CreateDesktopShortcut     = $false
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'YtDlp'
            PackageId                 = 'ytdlp'
            PackageName               = 'yt-dlp'
            WingetId                  = 'yt-dlp.yt-dlp'
            ChocolateyId              = 'yt-dlp'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'YtDlp' -Property 'DownloadSpec')
            InstallerArgs             = ''
            InstallKind               = 'Portable'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $true
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'YtDlp' -Property 'ExecutablePath')
            ShortcutName              = 'yt-dlp'
            CreateDesktopShortcut     = $false
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'CrystalDiskMark'
            PackageId                 = 'crystaldiskmark'
            PackageName               = 'CrystalDiskMark'
            WingetId                  = 'CrystalDewWorld.CrystalDiskMark'
            ChocolateyId              = 'crystaldiskmark'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'CrystalDiskMark' -Property 'DownloadSpec')
            InstallerArgs             = '/S'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'CrystalDiskMark' -Property 'ExecutablePath')
            ShortcutName              = 'CrystalDiskMark'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'CinebenchR23'
            PackageId                 = 'cinebench-r23'
            PackageName               = 'Cinebench R23'
            WingetId                  = 'Maxon.CinebenchR23'
            WingetSource              = 'winget'
            WingetUseId               = $true
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'CinebenchR23' -Property 'DownloadSpec')
            InstallerArgs             = ''
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AllowDirectDownloadFallback = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'CinebenchR23' -Property 'ExecutablePath')
            ShortcutName              = 'Cinebench R23'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'FurMark'
            PackageId                 = 'furmark'
            PackageName               = 'FurMark'
            WingetId                  = 'Geeks3D.FurMark.2'
            SkipWinget                = $true
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'FurMark' -Property 'DownloadSpec')
            InstallerArgs             = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $true
            AllowDirectDownloadFallback = $true
            SkipSignatureValidation   = $true
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'FurMark' -Property 'ExecutablePath')
            ShortcutName              = 'FurMark'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'PeaZip'
            PackageId                 = 'peazip'
            PackageName               = 'PeaZip'
            WingetId                  = 'Giorgiotani.Peazip'
            ChocolateyId              = 'peazip.install'
            SkipWinget                = $false
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'PeaZip' -Property 'DownloadSpec')
            InstallerArgs             = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
            InstallKind               = 'Installer'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AllowDirectDownloadFallback = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'PeaZip' -Property 'ExecutablePath')
            ShortcutName              = 'PeaZip'
            CreateDesktopShortcut     = $true
            PinToTaskbar              = $false
            PinPatterns               = @()
            PostInstallWindowPatterns = @()
        },
        @{
            ToolName                  = 'WinaeroTweaker'
            PackageId                 = 'winaero-tweaker'
            PackageName               = 'Winaero Tweaker'
            WingetId                  = ''
            SkipWinget                = $true
            GetDownloadSpec           = (Get-HunterToolScriptBlock -Name 'WinaeroTweaker' -Property 'DownloadSpec')
            InstallerArgs             = ''
            InstallKind               = 'Archive'
            AdditionalSuccessExitCodes= @()
            RefreshDownloadOnFailure  = $false
            AddToPath                 = $false
            PathProbe                 = ''
            GetExecutable             = (Get-HunterToolScriptBlock -Name 'WinaeroTweaker' -Property 'ExecutablePath')
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

    $shortcutPaths = Initialize-CachedAppShortcutSet `
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
