function Get-ChocolateyInstallerHelperContent {
    return @'
function Resolve-ChocolateyExecutablePath {
    $candidatePaths = @(
        (Get-Command choco.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        (Join-Path $env:ProgramData 'chocolatey\bin\choco.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    return $null
}

function Install-ChocolateyBootstrapInternal {
    $bootstrapUrl = 'https://community.chocolatey.org/install.ps1'
    $desktopPowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $bootstrapScriptPath = Join-Path $DownloadDir 'install-chocolatey.ps1'

    return (Invoke-WithNamedSemaphore -Name 'Global\HunterChocolateyBootstrap' -Action {
        try {
            $existingChocolateyPath = Resolve-ChocolateyExecutablePath
            if (-not [string]::IsNullOrWhiteSpace($existingChocolateyPath)) {
                return $existingChocolateyPath
            }

            Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapScriptPath -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 300 -ErrorAction Stop
            & $desktopPowerShellPath -NoProfile -ExecutionPolicy Bypass -File $bootstrapScriptPath *> $null
            if ([int]$LASTEXITCODE -ne 0) {
                throw "Chocolatey bootstrap exited with code $LASTEXITCODE"
            }

            $resolvedChocolateyPath = Resolve-ChocolateyExecutablePath
            if ([string]::IsNullOrWhiteSpace($resolvedChocolateyPath)) {
                throw 'Chocolatey bootstrap completed but choco.exe was still not found.'
            }

            return $resolvedChocolateyPath
        } finally {
            Remove-Item -Path $bootstrapScriptPath -Force -ErrorAction SilentlyContinue
        }
    })
}

function Install-ChocolateyPackageInternal {
    param(
        [string]$PackageName,
        [string]$ChocolateyId
    )

    if ([string]::IsNullOrWhiteSpace($ChocolateyId)) {
        throw "No Chocolatey package id is configured for $PackageName"
    }

    $chocoPath = Resolve-ChocolateyExecutablePath
    if ([string]::IsNullOrWhiteSpace($chocoPath)) {
        $chocoPath = Install-ChocolateyBootstrapInternal
    }

    if ([string]::IsNullOrWhiteSpace($chocoPath)) {
        throw "Chocolatey could not be resolved for $PackageName"
    }

    $env:Path = ((Split-Path -Parent $chocoPath) + ';' + $env:Path)
    $validChocolateyExitCodes = @(0, 1605, 1614, 1641, 3010)

    $chocoExitCode = Invoke-WithNamedSemaphore -Name 'Global\HunterChocolateyInstall' -Action {
        & $chocoPath install $ChocolateyId -y --no-progress --limit-output *> $null
        return [int]$LASTEXITCODE
    }

    if ($validChocolateyExitCodes -notcontains [int]$chocoExitCode) {
        throw "$PackageName install via Chocolatey package '$ChocolateyId' failed with exit code $chocoExitCode"
    }

    return [int]$chocoExitCode
}
'@
}
