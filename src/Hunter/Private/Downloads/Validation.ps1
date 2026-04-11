function Test-DownloadedFileLooksLikeUnexpectedHtmlResponse {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.htm', '.html', '.mhtml')) {
        return $false
    }

    try {
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
    } catch {
        return $false
    }
}

function Assert-DownloadedFileLooksValid {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SourceDescription = 'download'
    )

    $fileInfo = Get-Item -Path $Path -ErrorAction Stop
    if ($fileInfo.Length -le 0) {
        throw 'Downloaded file is empty'
    }

    if (Test-DownloadedFileLooksLikeUnexpectedHtmlResponse -Path $Path) {
        throw "$SourceDescription returned an HTML response instead of the expected payload."
    }

    return $fileInfo
}

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

    Initialize-HunterDirectory (Split-Path -Parent $Destination)

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

            Assert-DownloadedFileLooksValid -Path $Destination -SourceDescription "curl.exe download from $Url" | Out-Null

            Write-Log "File downloaded: $Destination"
            return $Destination
        } catch {
            $downloadErrors += "curl.exe: $($_.Exception.Message)"
            Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        $webResponse = Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing `
            -MaximumRedirection 10 `
            -TimeoutSec $TimeoutSec `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Hunter/2.0' } `
            -ErrorAction Stop

        $contentType = ''
        if ($null -ne $webResponse -and $null -ne $webResponse.Headers -and $null -ne $webResponse.Headers['Content-Type']) {
            $contentType = [string]$webResponse.Headers['Content-Type']
        }

        if (-not [string]::IsNullOrWhiteSpace($contentType) -and $contentType -match '(?i)text/html|application/xhtml\+xml') {
            throw "Unexpected HTTP content type '$contentType' returned for $Url"
        }

        Assert-DownloadedFileLooksValid -Path $Destination -SourceDescription "Invoke-WebRequest download from $Url" | Out-Null
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

