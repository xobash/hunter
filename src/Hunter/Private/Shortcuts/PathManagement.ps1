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
            $programFilesX86Root = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
            $approvedRoots = @(
                $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'Microsoft' }),
                $env:ProgramData,
                $script:ProgramFilesRoot,
                $programFilesX86Root
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
            $approvedMarkers = @('OneDrive', 'Microsoft OneDrive', 'Teams', 'EdgeUpdate')

            $resolvedPath = [System.IO.Path]::GetFullPath($Path)
            $isUnderApprovedRoot = $false
            foreach ($approvedRoot in $approvedRoots) {
                $resolvedApprovedRoot = [System.IO.Path]::GetFullPath($approvedRoot)
                if ($resolvedPath.StartsWith($resolvedApprovedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isUnderApprovedRoot = $true
                    break
                }
            }

            $hasApprovedMarker = $false
            foreach ($approvedMarker in $approvedMarkers) {
                if ($resolvedPath -match ("(?i)(?:\\|/){0}(?:\\|/|$)" -f [regex]::Escape($approvedMarker))) {
                    $hasApprovedMarker = $true
                    break
                }
            }

            if (-not ($isUnderApprovedRoot -and $hasApprovedMarker)) {
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

