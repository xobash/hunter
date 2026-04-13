function Initialize-InstallerJobHelpers {
    $helperContent = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function global:Write-InstallerHelperWarning {
    param([string]$Message)

    try {
        [Console]::Error.WriteLine("[Hunter] $Message")
    } catch {
        Write-Host "[Hunter] $Message"
    }
}

function global:Invoke-WithNamedSemaphore {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [int]$MaxConcurrency = 1,
        [int]$WaitTimeoutSeconds = 1800
    )

    $safeMaxConcurrency = [Math]::Max($MaxConcurrency, 1)
    $createdNew = $false
    $semaphore = $null
    $hasHandle = $false

    try {
        $semaphore = New-Object System.Threading.Semaphore($safeMaxConcurrency, $safeMaxConcurrency, $Name, ([ref]$createdNew))
        $hasHandle = $semaphore.WaitOne([TimeSpan]::FromSeconds([Math]::Max($WaitTimeoutSeconds, 1)))
        if (-not $hasHandle) {
            throw "Timed out waiting for semaphore '$Name'."
        }

        return (& $Action)
    } finally {
        if ($hasHandle -and $null -ne $semaphore) {
            try {
                [void]$semaphore.Release()
            } catch {
                Write-InstallerHelperWarning "failed to release semaphore '$Name': $($_.Exception.Message)"
            }
        }

        if ($null -ne $semaphore) {
            $semaphore.Dispose()
        }
    }
}

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

function global:Test-DownloadedFileLooksLikeUnexpectedHtmlResponse {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.htm', '.html', '.mhtml')) {
        return $false
    }

    $sampleLength = 4096
    $buffer = New-Object byte[] $sampleLength
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

function global:Resolve-DownloadedFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Downloaded file not found: $Path"
    }

    if (Test-DownloadedFileLooksLikeUnexpectedHtmlResponse -Path $Path) {
        throw "Downloaded file at $Path appears to be an HTML error page rather than the expected package payload."
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

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actualHash = (Get-FileHash -Path $resolvedFile.Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $normalizedExpectedHash = $ExpectedSha256.ToLowerInvariant()
        if ($actualHash -ne $normalizedExpectedHash) {
            $signatureStatus = if ($null -eq $signature) { 'Unknown' } else { [string]$signature.Status }
            throw "${PackageName} trust validation failed. Signature status: ${signatureStatus}. Expected SHA256 ${normalizedExpectedHash} but received ${actualHash}"
        }

        if ($null -eq $signature -or [string]$signature.Status -ne 'Valid') {
            return $resolvedFile.Path
        }
    }

    if ($null -ne $signature -and [string]$signature.Status -eq 'Valid') {
        return $resolvedFile.Path
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

    return (Invoke-WithNamedSemaphore -Name 'Global\HunterWingetInstall' -MaxConcurrency 3 -WaitTimeoutSeconds $WaitTimeoutSeconds -Action {
        & winget @Arguments *> $null
        return $LASTEXITCODE
    })
}

function global:Invoke-DirectInstallerWithMutex {
    param(
        [scriptblock]$Action,
        [int]$WaitTimeoutSeconds = 1800
    )

    return (Invoke-WithNamedSemaphore -Name 'Global\HunterDirectInstall' -MaxConcurrency 1 -WaitTimeoutSeconds $WaitTimeoutSeconds -Action $Action)
}
'@

    if ($null -ne (Get-Command -Name 'Get-ChocolateyInstallerHelperContent' -ErrorAction SilentlyContinue)) {
        $helperContent = @(
            $helperContent
            (Get-ChocolateyInstallerHelperContent)
        ) -join [Environment]::NewLine
    }

    try {
        $script:InstallerJobHelperContent = $helperContent
        . ([scriptblock]::Create($helperContent))
    } catch {
        Write-Log "Failed to initialize installer job helpers: $_" 'ERROR'
        throw
    }
}

Initialize-InstallerJobHelpers

function Initialize-InstallerHelpers {
    if ($null -eq (Get-Command -Name 'Confirm-InstallerSignature' -ErrorAction SilentlyContinue)) {
        Initialize-InstallerJobHelpers
    }
}

function Wait-ProcessBatchUntilDeadline {
    param(
        [System.Collections.IEnumerable]$ProcessInfos,
        [int]$TimeoutSeconds = 30,
        [string]$BatchDescription = 'Process batch',
        [int]$MaxTimeoutExamples = 8
    )

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max($TimeoutSeconds, 1))
    $pendingProcesses = [System.Collections.Generic.List[object]]::new()

    foreach ($procInfo in @($ProcessInfos)) {
        if ($null -eq $procInfo -or $null -eq $procInfo.Process) {
            continue
        }

        [void]$pendingProcesses.Add($procInfo)
    }

    while ($pendingProcesses.Count -gt 0) {
        for ($idx = $pendingProcesses.Count - 1; $idx -ge 0; $idx--) {
            $procInfo = $pendingProcesses[$idx]
            try {
                if (-not $procInfo.Process.HasExited) {
                    continue
                }

                if ($procInfo.Process.ExitCode -ne 0) {
                    Write-Log "$($procInfo.Description) exited with code $($procInfo.Process.ExitCode)." 'WARN'
                }
            } catch {
                Write-Log "Failed to observe completion for $($procInfo.Description): $($_.Exception.Message)" 'WARN'
            }

            $pendingProcesses.RemoveAt($idx)
        }

        if ($pendingProcesses.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) {
            break
        }

        Start-Sleep -Milliseconds 200
    }

    $timedOutDescriptions = New-Object 'System.Collections.Generic.List[string]'

    foreach ($procInfo in @($pendingProcesses.ToArray())) {
        try {
            if ($procInfo.Process.HasExited) {
                if ($procInfo.Process.ExitCode -ne 0) {
                    Write-Log "$($procInfo.Description) exited with code $($procInfo.Process.ExitCode)." 'WARN'
                }
            } else {
                [void]$timedOutDescriptions.Add([string]$procInfo.Description)
            }
        } catch {
            Write-Log "Failed to observe completion for $($procInfo.Description): $($_.Exception.Message)" 'WARN'
        }
    }

    if ($timedOutDescriptions.Count -gt 0) {
        $sampleSize = [Math]::Min($timedOutDescriptions.Count, [Math]::Max($MaxTimeoutExamples, 1))
        $sampleDescriptions = @($timedOutDescriptions | Select-Object -First $sampleSize)
        $remainingCount = $timedOutDescriptions.Count - $sampleSize
        $sampleSuffix = if ($remainingCount -gt 0) {
            " +$remainingCount more"
        } else {
            ''
        }
        $sampleText = if ($sampleDescriptions.Count -gt 0) {
            " Examples: $($sampleDescriptions -join '; ')."
        } else {
            ''
        }
        $timeoutWindow = Format-ElapsedDuration -Duration ([TimeSpan]::FromSeconds([Math]::Max($TimeoutSeconds, 1)))
        Write-Log "$BatchDescription exceeded the $timeoutWindow wait window; $($timedOutDescriptions.Count) process(es) were still running.$sampleSuffix$sampleText" 'WARN'
    }
}
