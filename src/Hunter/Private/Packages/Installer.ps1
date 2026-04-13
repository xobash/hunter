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
        [hashtable]$ResultsByPackageId,
        [switch]$TreatAsTimeout
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
        $jobState = if ($TreatAsTimeout) { 'TimedOut' } else { [string]$JobInfo.Job.State }
        $jobStateIndicatesFailure = $jobState -in @('Failed', 'Stopped')
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
            if (-not $TreatAsTimeout -and $JobInfo.Target.ContainsKey('GetExecutable') -and $null -ne $JobInfo.Target.GetExecutable) {
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
                $packageResult.Message = "$($JobInfo.Target.PackageName) installation verified after background job state $jobState"
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

            if ($jobStateIndicatesFailure) {
                $jobMessage = "Installer job ended in state ${jobState}. ${jobMessage}".Trim()
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

        if (-not $TreatAsTimeout -and -not $packageResult.Success -and $JobInfo.Target.ContainsKey('GetExecutable') -and $null -ne $JobInfo.Target.GetExecutable) {
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
                $packageResult.Message = "$($JobInfo.Target.PackageName) installation verified after background job state $jobState"
            }
        }

        $jobDiagnostics = @(
            @($jobReceiveErrors | ForEach-Object { $_.ToString() })
            @($JobInfo.Job.ChildJobs | ForEach-Object { $_.Error } | ForEach-Object { $_.ToString() })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

        if ($jobStateIndicatesFailure -and -not $packageResult.Success) {
            $diagnosticText = @($jobDiagnostics) -join ' | '
            if ([string]::IsNullOrWhiteSpace($diagnosticText)) {
                $diagnosticText = $packageResult.Message
            }

            if ([string]::IsNullOrWhiteSpace($diagnosticText)) {
                $diagnosticText = 'Installer job did not return a structured result before failing.'
            }

            $packageResult.Message = "Installer job ended in state ${jobState}. ${diagnosticText}".Trim()
        } elseif ($jobStateIndicatesFailure -and $packageResult.Success) {
            $diagnosticText = @($jobDiagnostics) -join ' | '
            if (-not [string]::IsNullOrWhiteSpace($diagnosticText)) {
                $packageResult.Message = "$($packageResult.Message) (job state: $jobState; diagnostics: $diagnosticText)"
            } else {
                $packageResult.Message = "$($packageResult.Message) (job state: $jobState)"
            }
        }

        if ($TreatAsTimeout) {
            $diagnosticText = @(
                @($jobReceiveErrors | ForEach-Object { $_.ToString() })
                @($JobInfo.Job.ChildJobs | ForEach-Object { $_.Error } | ForEach-Object { $_.ToString() })
                @([string]$packageResult.Message)
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

            $packageResult.Success = $false
            $packageResult.Skipped = $false
            $packageResult.PathEntries = @()
            $packageResult.Message = 'Installer job timed out before completion and was stopped.'
            if (@($diagnosticText).Count -gt 0) {
                $packageResult.Message = "$($packageResult.Message) Diagnostics: $($diagnosticText -join ' | ')"
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
        if (Resolve-SkipAppDownloadsPreference) {
            Write-Log 'App downloads and installs were skipped by user preference. Package pipeline will not run.' 'INFO'
            return (New-TaskSkipResult -Reason 'App downloads and installs were skipped by the user')
        }
        if ($script:PackagePipelineBlocked) {
            Write-Log "App download pipeline is blocked: $($script:PackagePipelineBlockReason)" 'WARN'
            return (New-TaskSkipResult -Reason $script:PackagePipelineBlockReason)
        }
        if (-not (Ensure-WingetFunctional)) {
            return $false
        }

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
                    $resolvedTarget.ChocolateyId = if ($target.ContainsKey('ChocolateyId') -and -not [string]::IsNullOrWhiteSpace([string]$target.ChocolateyId)) {
                        [string]$target.ChocolateyId
                    } else {
                        ''
                    }
                    $resolvedTarget.AllowDirectDownloadFallback = if ($target.ContainsKey('AllowDirectDownloadFallback')) {
                        [bool]$target.AllowDirectDownloadFallback
                    } else {
                        $true
                    }
                    $resolvedTarget.RefreshDownloadOnFailure = if ($target.ContainsKey('RefreshDownloadOnFailure')) {
                        [bool]$target.RefreshDownloadOnFailure
                    } else {
                        $false
                    }
                    $resolvedTarget.SkipSignatureValidation = if ($target.ContainsKey('SkipSignatureValidation')) {
                        [bool]$target.SkipSignatureValidation
                    } else {
                        $false
                    }
                    $resolvedTarget.AddToPath = if ($target.ContainsKey('AddToPath')) {
                        [bool]$target.AddToPath
                    } else {
                        $false
                    }
                    $resolvedTarget.PathProbe = if ($target.ContainsKey('PathProbe') -and -not [string]::IsNullOrWhiteSpace([string]$target.PathProbe)) {
                        [string]$target.PathProbe
                    } else {
                        ''
                    }
                    $resolvedTarget.ExpectedSha256 = if ($target.ContainsKey('ExpectedSha256') -and -not [string]::IsNullOrWhiteSpace([string]$target.ExpectedSha256)) {
                        [string]$target.ExpectedSha256
                    } else {
                        ''
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
                        if ((($downloadSpec -is [System.Collections.IDictionary] -and $downloadSpec.Contains('ExpectedSha256')) -or
                            ($null -ne $downloadSpec.PSObject.Properties['ExpectedSha256'])) -and
                            -not [string]::IsNullOrWhiteSpace([string]$downloadSpec.ExpectedSha256)) {
                            $resolvedTarget.ExpectedSha256 = [string]$downloadSpec.ExpectedSha256
                        }
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
                    ChocolateyId              = $resolvedTarget.ChocolateyId
                    SkipWinget                 = $resolvedTarget.SkipWinget
                    DownloadUrl                = $resolvedTarget.DownloadUrl
                    DownloadFileName           = $resolvedTarget.DownloadFileName
                    InstallerArgs              = $resolvedTarget.InstallerArgs
                    InstallKind                = $resolvedTarget.InstallKind
                    AdditionalSuccessExitCodes = @($resolvedTarget.AdditionalSuccessExitCodes)
                    RefreshDownloadOnFailure   = $resolvedTarget.RefreshDownloadOnFailure
                    AllowDirectDownloadFallback = $resolvedTarget.AllowDirectDownloadFallback
                    SkipSignatureValidation    = $resolvedTarget.SkipSignatureValidation
                    ExpectedSha256             = $resolvedTarget.ExpectedSha256
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
                            [bool]$SkipSignatureValidation = $false,
                            [string]$ExpectedSha256 = ''
                        )

                        $resolvedFile = Resolve-DownloadedFile -Path $Path
                        if (-not $SkipSignatureValidation -or -not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                            Confirm-InstallerSignature -PackageName $PackageName -Path $resolvedFile.Path -ExpectedSha256 $ExpectedSha256 | Out-Null
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
                        $expectedSha256 = ''
                        if (($InstallTarget -is [System.Collections.IDictionary] -and $InstallTarget.Contains('ExpectedSha256')) -or
                            ($null -ne $InstallTarget.PSObject.Properties['ExpectedSha256'])) {
                            $expectedSha256 = [string]$InstallTarget.ExpectedSha256
                        }

                        switch ($InstallTarget.InstallKind) {
                            'Installer' {
                                Install-InstallerPackageInternal `
                                    -PackageName $InstallTarget.PackageName `
                                    -Path $FilePath `
                                    -InstallerArgs $InstallTarget.InstallerArgs `
                                    -AdditionalSuccessExitCodes $InstallTarget.AdditionalSuccessExitCodes `
                                    -SkipSignatureValidation $skipSignatureValidation `
                                    -ExpectedSha256 $expectedSha256
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

                        if (-not [string]::IsNullOrWhiteSpace([string]$Target.ChocolateyId)) {
                            try {
                                $chocoExitCode = Install-ChocolateyPackageInternal -PackageName $Target.PackageName -ChocolateyId ([string]$Target.ChocolateyId)
                                $result.Success = $true
                                $result.Message = "$($Target.PackageName) installed via Chocolatey ($($Target.ChocolateyId), exit code $chocoExitCode)"
                                return [pscustomobject]$result
                            } catch {
                                if (-not $Target.AllowDirectDownloadFallback) {
                                    throw
                                }
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
                                } catch {
                                    Write-InstallerHelperWarning "Failed to enforce TLS 1.2 for $($Target.PackageName) download: $($_.Exception.Message)"
                                }

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
                        $expectedSha256 = ''
                        if (($Target -is [System.Collections.IDictionary] -and $Target.Contains('ExpectedSha256')) -or
                            ($null -ne $Target.PSObject.Properties['ExpectedSha256'])) {
                            $expectedSha256 = [string]$Target.ExpectedSha256
                        }

                        if ($skipSignatureValidation -and -not [string]::IsNullOrWhiteSpace($expectedSha256)) {
                            $result.Message = "$($Target.PackageName) installed via direct download (SHA256 verified)"
                        } elseif ($skipSignatureValidation) {
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
                Write-Log "Installer finalize timed out after 30:00. Stopping still-running job(s): $($timedOutNames -join ', ')" 'WARN'
            }

            foreach ($jobInfo in @($pendingJobs)) {
                $elapsed = Format-ElapsedDuration -Duration ((Get-Date) - $jobInfo.StartedAt)
                if ($jobInfo.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
                    try {
                        Stop-Job -Job $jobInfo.Job -ErrorAction Stop | Out-Null
                    } catch {
                        Write-Log "Failed to stop timed-out installer job $($jobInfo.Target.PackageName) cleanly: $($_.Exception.Message)" 'WARN'
                    }
                }

                Write-Log "Collecting timed-out installer result: $($jobInfo.Target.PackageName) after $elapsed" 'INFO'
                $jobResult = Receive-ParallelInstallerJobResult -JobInfo $jobInfo -ResultsByPackageId $resultsByPackageId -TreatAsTimeout
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

        foreach ($target in $targets) {
            $result = $resultsByPackageId[$target.PackageId]
            if ($null -eq $result -or -not $result.Success) {
                continue
            }

            if ($script:PostInstallCompletion.ContainsKey($target.PackageId) -and [bool]$script:PostInstallCompletion[$target.PackageId]) {
                continue
            }

            $postInstallHandler = $null
            if ($target.ContainsKey('ToolName') -and -not [string]::IsNullOrWhiteSpace([string]$target.ToolName)) {
                $postInstallHandler = Get-HunterToolScriptBlock -Name ([string]$target.ToolName) -Property 'PostInstall'
            }

            if ($null -ne $postInstallHandler) {
                & $postInstallHandler
            }
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
