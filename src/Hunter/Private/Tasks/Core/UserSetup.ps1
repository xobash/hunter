function Invoke-EnsureLocalStandardUser {
    if (Test-TaskCompleted -TaskId 'core-local-user-v2') {
        Write-Log "Local user already ensured, skipping"
        return $true
    }

    if (-not (Resolve-CreateLocalUserPreference)) {
        Write-Log "Standard user creation declined by user; skipping" 'INFO'
        return (New-TaskSkipResult -Reason 'Standard user creation declined by user')
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
            Write-Log 'LocalAccounts cmdlets unavailable; falling back to net.exe for local user management.' 'INFO'

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
                    Write-Log "net.exe fallback failed for local user 'user' with exit code ${netUserExitCode}." 'WARN'
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
                        throw "net.exe failed to provision the local user account with exit code ${netUserExitCode}. net.exe output: ${netUserMessage}. ADSI fallback failed: $($_.Exception.Message)"
                    }

                    throw "net.exe failed to provision the local user account with exit code ${netUserExitCode}. ADSI fallback failed: $($_.Exception.Message)"
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

    if (-not (Resolve-CreateLocalUserPreference)) {
        Write-Log "Standard user creation declined; skipping autologin" 'INFO'
        return (New-TaskSkipResult -Reason 'Autologin requires the standard user account, which the user declined to create')
    }

    try {
        $passwordContext = Resolve-HunterLocalUserPassword -UserExists:$true
        if ($null -eq $passwordContext -or [string]::IsNullOrWhiteSpace($passwordContext.Password)) {
            Write-Log "Autologin was not configured because Hunter does not have a managed credential for local user 'user'." 'WARN'
            return (New-TaskSkipResult -Reason 'Autologin requires a managed local-user credential')
        }

        $autologonPath = Join-Path $script:DownloadDir 'Autologon64.exe'
        $validatedAutologonPath = $null

        Initialize-InstallerHelpers
        $existingAutologon = Get-Item -Path $autologonPath -ErrorAction SilentlyContinue
        if ($null -ne $existingAutologon -and $existingAutologon.Length -gt 0) {
            try {
                $validatedAutologonPath = Confirm-InstallerSignature `
                    -PackageName 'Autologon' `
                    -Path $autologonPath `
                    -ExpectedSha256 $script:Autologon64Sha256
                Write-Log 'Reusing cached Autologon64.exe after trust validation.' 'INFO'
            } catch {
                Write-Log "Cached Autologon64.exe failed trust validation and will be refreshed: $($_.Exception.Message)" 'WARN'
                Remove-Item -Path $autologonPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ([string]::IsNullOrWhiteSpace($validatedAutologonPath)) {
            Download-File -Url 'https://live.sysinternals.com/Autologon64.exe' -Destination $autologonPath -Force:$true | Out-Null
            if (-not (Test-Path $autologonPath)) {
                Write-Log "Autologon64.exe not found after download" 'ERROR'
                return $false
            }

            $validatedAutologonPath = Confirm-InstallerSignature `
                -PackageName 'Autologon' `
                -Path $autologonPath `
                -ExpectedSha256 $script:Autologon64Sha256
        }

        Invoke-NativeCommandChecked -FilePath $validatedAutologonPath -ArgumentList @('/accepteula', 'user', '.', $passwordContext.Password) | Out-Null
        Write-Log "Autologin configured"
        return $true

    } catch {
        Write-Log "Failed to configure autologin : $_" 'ERROR'
        return $false
    }
}
