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

    Initialize-HunterDirectory (Split-Path -Parent $Destination)

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
        $tlsWarning = $null

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch {
            $tlsWarning = "TLS 1.2 enforcement failed: $($_.Exception.Message)"
        }

        function Test-PrefetchFileLooksLikeUnexpectedHtmlResponse {
            param([string]$Path)

            if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
                return $false
            }

            $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
            if ($extension -in @('.htm', '.html', '.mhtml')) {
                return $false
            }

            $buffer = New-Object byte[] 4096
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            } finally {
                $stream.Dispose()
            }

            if ($bytesRead -le 0) {
                return $false
            }

            $sampleText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
            $trimmedText = $sampleText.TrimStart([char]0xFEFF, [char]0x0000, ' ', "`t", "`r", "`n")
            return ($trimmedText -match '^(?i)(<!doctype\s+html|<html\b|<head\b|<body\b|<title\b)')
        }

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

            if (Test-PrefetchFileLooksLikeUnexpectedHtmlResponse -Path $tempPath) {
                throw 'Downloaded response was HTML instead of the expected asset payload.'
            }

            $finalFile = Get-Item -Path $Destination -ErrorAction SilentlyContinue
            if ($null -ne $finalFile -and $finalFile.Length -gt 0) {
                Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                $successMessage = 'Already downloaded by another task.'
                if (-not [string]::IsNullOrWhiteSpace($tlsWarning)) {
                    $successMessage = "$successMessage $tlsWarning"
                }
                return [pscustomobject]@{
                    AssetKey    = $AssetKey
                    AssetName   = $AssetName
                    Destination = $Destination
                    Success     = $true
                    HadWarning  = (-not [string]::IsNullOrWhiteSpace($tlsWarning))
                    Message     = $successMessage
                }
            }

            Move-Item -Path $tempPath -Destination $Destination -Force
            $successMessage = 'Prefetch completed.'
            if (-not [string]::IsNullOrWhiteSpace($tlsWarning)) {
                $successMessage = "$successMessage $tlsWarning"
            }

            return [pscustomobject]@{
                AssetKey    = $AssetKey
                AssetName   = $AssetName
                Destination = $Destination
                Success     = $true
                HadWarning  = (-not [string]::IsNullOrWhiteSpace($tlsWarning))
                Message     = $successMessage
            }
        } catch {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
            $errorMessages = New-Object 'System.Collections.Generic.List[string]'
            if (-not [string]::IsNullOrWhiteSpace($tlsWarning)) {
                [void]$errorMessages.Add($tlsWarning)
            }
            if (-not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                [void]$errorMessages.Add($_.Exception.Message)
            }
            return [pscustomobject]@{
                AssetKey    = $AssetKey
                AssetName   = $AssetName
                Destination = $Destination
                Success     = $false
                HadWarning  = (-not [string]::IsNullOrWhiteSpace($tlsWarning))
                Message     = (($errorMessages | Select-Object -Unique) -join ' | ')
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

                if ($outputItem -is [System.Collections.IDictionary] -and
                    $outputItem.Contains('AssetKey') -and
                    $outputItem.Contains('Success') -and
                    $outputItem.Contains('Message')) {
                    $result = [pscustomobject]$outputItem
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
                $receiveMessage = if ($jobReceiveErrors.Count -gt 0) {
                    ($jobReceiveErrors | ForEach-Object { $_.ToString() }) -join ' | '
                } else {
                    "Job finished in state $($jobInfo.Job.State) without returning a structured result."
                }

                $result = [pscustomobject]@{
                    AssetKey    = $jobInfo.AssetKey
                    AssetName   = $jobInfo.AssetName
                    Destination = $jobInfo.Destination
                    Success     = $false
                    Message     = $receiveMessage
                }
            }

            $resultHadWarning = ($null -ne $result.PSObject.Properties['HadWarning'] -and [bool]$result.HadWarning)
            if ($result.Success -and -not $resultHadWarning) {
                $script:PrefetchedExternalAssets[$result.AssetKey] = $true
                Write-Log "Background asset ready: $($jobInfo.AssetName) after $elapsed - $($result.Message)" 'SUCCESS'
            } elseif ($result.Success -and $resultHadWarning) {
                $script:PrefetchedExternalAssets[$result.AssetKey] = $true
                Write-Log "Background asset ready with warnings: $($jobInfo.AssetName) after $elapsed - $($result.Message)" 'WARN'
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

