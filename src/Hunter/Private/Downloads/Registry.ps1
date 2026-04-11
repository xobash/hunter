$script:ToolRegistry = @{}

function Register-HunterTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$DownloadSpec = $null,
        [scriptblock]$ExecutablePath = $null,
        [scriptblock]$PostInstall = $null
    )

    $script:ToolRegistry[$Name] = [pscustomobject]@{
        Name           = $Name
        DownloadSpec   = $DownloadSpec
        ExecutablePath = $ExecutablePath
        PostInstall    = $PostInstall
    }
}

function Get-HunterTool {
    param([Parameter(Mandatory)][string]$Name)

    if ($script:ToolRegistry.ContainsKey($Name)) {
        return $script:ToolRegistry[$Name]
    }

    return $null
}

function Get-HunterToolScriptBlock {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('DownloadSpec', 'ExecutablePath', 'PostInstall')]
        [string]$Property
    )

    $tool = Get-HunterTool -Name $Name
    if ($null -eq $tool) {
        return $null
    }

    return $tool.$Property
}

function Get-HunterToolRegistry {
    return @($script:ToolRegistry.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value })
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
