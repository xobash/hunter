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

        Initialize-HunterDirectory (Split-Path -Parent $ShortcutPath)
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

function Initialize-DesktopShortcut {
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

function Initialize-AppShortcutSet {
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

function Initialize-CachedAppShortcutSet {
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

    $shortcutPaths = Initialize-AppShortcutSet `
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

