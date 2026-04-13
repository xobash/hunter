function Get-HunterPrivateAssetManifest {
    return @(
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Bootstrap\Context.ps1'; Sha256 = '31bb367c507e4550ffa57352c7bd1b96ca34afdb6bda5875b965f0ff584ba04f'; Order = 10; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Bootstrap\Config.ps1'; Sha256 = 'da0c7bb6b38c92dfd445654cda129b9a763abe246f82a977c1608e8863abddb3'; Order = 20; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Common\Common.ps1'; Sha256 = '32f5ee6d293f169555ce724fb263c7d7d4612cbe5ee8d93e0de38d5b1d048e12'; Order = 30; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Common\PathPolicy.ps1'; Sha256 = 'b0d41621d6405049efc4b34ce765fd610f26a3c0c0136dfe9d6568a4a15c8df1'; Order = 40; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Infrastructure\NativeSystem.ps1'; Sha256 = '326676f71da575447b5d3abf786cd3290dbb7537db12c7cc951996bb2852d467'; Order = 50; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Registry\Operations.ps1'; Sha256 = 'b3335d079dcc57e24871dc2cdbb9fb953ead9580b10e4cf608f9ff0972faf29a'; Order = 60; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Registry\UserHives.ps1'; Sha256 = 'd294d31ff578f1765bc8050106dc3bb010e145c882ee02460655acbc5436cad6'; Order = 70; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Services\ServiceControl.ps1'; Sha256 = '0ebfb6a7b214e6f35ebe2de6c4478ac5aaea3405b451ce76bcfe90078159ebe4'; Order = 80; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\Interaction.ps1'; Sha256 = '049a5a1233cc2fae59d698de111b7566d37b7c840b807c48395995610769cce0'; Order = 90; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Crypto\LocalCredentials.ps1'; Sha256 = 'febb2d36ef6a1909751c50eb9b5fe0a7cd14dc6ca1049ab0232ce6f1ed9b80db'; Order = 100; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\Detection.ps1'; Sha256 = 'd6d234dbc7ec0342cf1e115667de16b01652237a055a8ca17959c10049a0226c'; Order = 110; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\Hosts.ps1'; Sha256 = 'd5a5ee2f0a9437b36907b80c99aac9371cde9301e9685d171846331a779749ce'; Order = 120; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\PerformanceSupport.ps1'; Sha256 = '43e253fb20ce15bb11198af1c5ecc192979b84ecb2bf36392d02771d750bb6b0'; Order = 130; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\PerformanceTuning.ps1'; Sha256 = '081cab24a5e44472c2e1f5f38c725c6a9fc0880e9e5cbd92148526ce1c3e107d'; Order = 140; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Shortcuts\PathManagement.ps1'; Sha256 = 'a9a136791badf5b1c9be88cbd074ace465a16cae4a8361442774621b489126ec'; Order = 150; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Shortcuts\ShortcutOps.ps1'; Sha256 = 'ae02086f48acfe2ff786a9e3c77e08b710e6bddaba131a67ad61413eb5db3ead'; Order = 160; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Shortcuts\TaskbarOps.ps1'; Sha256 = '4bfc698c21f73e599a886b91126a7885e61ae9d1aec22cdbf25ec456a4c5e256'; Order = 170; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Gpu\GpuTuning.ps1'; Sha256 = '44758c3391771fb553059bf0444275447a3b4bb3cc0fbc12cd3e292d37465916'; Order = 180; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Apps\AppCatalog.ps1'; Sha256 = '525ac67ea77089dd3e67311892ee8d9e74f4894e61e1ce0e12f501f39c80cde6'; Order = 190; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Apps\AppRemoval.ps1'; Sha256 = '51fdf02b5550483189bf3728d897296d5b45da59b0bf265d9f1da4f117372d16'; Order = 200; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Apps\AppxRemoval.ps1'; Sha256 = '5bc498767b84a41825ab7e2e418c5b0743f10e921247341d90390a4818b5e42c'; Order = 210; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Registry.ps1'; Sha256 = '64940f4679c1e3ad5739851461b5f3c5f0ff1bbbb3cd8214903fdb895ff15f72'; Order = 220; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Validation.ps1'; Sha256 = '2c1bafd0d294b7c87e4df2966cb586ab09eea53b815b999b842750130cb57be0'; Order = 230; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Prefetch.ps1'; Sha256 = '9697486a6b692d61e99fa01c7605ca88009ab3366d57daa3658b938b76955180'; Order = 240; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\PowerShell7.ps1'; Sha256 = '4de2b443cb2289131bb11ede1ff2f845821b0dbe424a7aa69b0a3bc58491627e'; Order = 250; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\Brave.ps1'; Sha256 = 'd3e155f00ef0e631227848b6dcdb42d2991a48deb4f6cd3de3260dde83fcc9ff'; Order = 260; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\Parsec.ps1'; Sha256 = 'ae3ea4908a0b17e8ddfcfc4ca1f60ab5c775311a857c67a9ef69a47f3b126126'; Order = 270; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\Steam.ps1'; Sha256 = 'ad407d442092f5eae64a91c7d9ec032100b976c0b31519404263f0c4e02e27e4'; Order = 280; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\FFmpeg.ps1'; Sha256 = '5155fece89bc99a2f5af74d06beb85034ebaa00214482cb8608bc26495974c74'; Order = 290; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\YtDlp.ps1'; Sha256 = 'ae7ae187194e52cabc2d1c8e01f337a4f52dddb439a86b94764acf62d293fe62'; Order = 300; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\CrystalDiskMark.ps1'; Sha256 = '9e4968fdaeabd11260444ce5ffa8175279d89a6ea215df75ab3e82f34198e1e2'; Order = 310; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\CinebenchR23.ps1'; Sha256 = '556a98c1a96a83aab638a15e159040d129f74de697b6064b003f14d572e5d855'; Order = 320; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\FurMark.ps1'; Sha256 = '25c4eafddbf0bf497eb9cef80fb7e49cb1ec660af939e10ca7e71c5a5237867c'; Order = 330; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\PeaZip.ps1'; Sha256 = '6d5f764dabef83384f4b611eb3411c0147e3b1454ba5d6befab44a1a3516ee94'; Order = 340; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Specs\WinaeroTweaker.ps1'; Sha256 = '064308fb932ba7c6f4ce1d93f867ca4025926ed440ac47745dbf258c33ff6826'; Order = 350; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Chocolatey.ps1'; Sha256 = '8ca186b1da8266fed8122b243e11940b83640d64ec31e45da5ae07c52a8f42a0'; Order = 360; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Helpers.ps1'; Sha256 = 'ea51338f8bb665d762e4ac56dfc5d233453dab94b6c839b7f92e43c36876ab2e'; Order = 370; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Winget.ps1'; Sha256 = 'b74c06f3163e34a95263e96c9589300437972c9c5b37c76f3af52d16341db5c1'; Order = 380; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Catalog.ps1'; Sha256 = '4ff948d0e267443c66085977d8cb710f914d1f697cdc5efa6ea2a2b8c9d8dd93'; Order = 390; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Installer.ps1'; Sha256 = 'af11266202d998a7992d94e93110e01846333737d15b482b01a15fdd81934595'; Order = 400; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\UI\ProgressWindow.ps1'; Sha256 = '8f751b9b4a7ceb4eae64f9a8f2294c49c4470d22c15f1ddcb254aa94af0b7b44'; Order = 410; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\UI\ExplorerOps.ps1'; Sha256 = 'f10ecc0020fd4e8f6376e402c5d516387f6c03227bed48cf8292a10efabc67b1'; Order = 420; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Preflight.ps1'; Sha256 = '73af899b401d6883a1b51b24c65ef4742d16fe3a5a7c743c8addb0e0942671fa'; Order = 430; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Core\UserSetup.ps1'; Sha256 = '855d52a1af564629923d9a6945c905eb51b671e9c4005d01f5b12d6509e090d5'; Order = 440; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\UI.ps1'; Sha256 = '99be3699c6450f319605ebda5526a2cd773ff0b841d1c14f10730f97b0cf9cc6'; Order = 450; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Explorer.ps1'; Sha256 = '99f5b5964ee357f1e6a71633b1b377c556ab9e88672c20c281fcaceafef064ab'; Order = 460; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Edge.ps1'; Sha256 = '81b8ec57a1645c325eb101416d78d08b9edde4b4aad313e67396679a0df857ee'; Order = 470; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\OneDriveCopilot.ps1'; Sha256 = 'a7a2c1475513f49e78c744a4c075275a0b7cda41523d781a593493469d0485e6'; Order = 480; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Specialized.ps1'; Sha256 = 'a76533d3b13bc2e6c09fddc0c04f36f8486b5aaec1eee1aab262982e976925e5'; Order = 490; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Privacy.ps1'; Sha256 = 'd0b2d59fa540967a24551a925feac0e299deba96470d5dd262d2b4e836768c13'; Order = 500; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Features.ps1'; Sha256 = 'd7dda6dc9710d94568e04c94661aaa29db37c37a0d1137dd1bb6d6a5af247a53'; Order = 510; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Hardware.ps1'; Sha256 = '51ba71d9f581669af6ec7c4e0b6a7d15767f2adff349ec19cccf2d7975dfcc47'; Order = 520; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Cleanup.ps1'; Sha256 = 'b8409a31cc7646eabfecb2d9522d3c1a02b963d1127dd356feb7161c0a488e86'; Order = 530; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Catalog.ps1'; Sha256 = 'ca30274f6d7168f8315e252fefa2d3560e6174c34aee27fdcdb684faa1690c8a'; Order = 540; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Execution\Engine.ps1'; Sha256 = '692d4a9140e60e4e4407de7e0a89b6fa2b9013583ed0e90b53fbfc8834513a44'; Order = 550; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Execution\Resume.ps1'; Sha256 = 'b8ed80a70269875ca2cf7b38b066975e204d393bd86fbe9741b7aeedd61a5c74'; Order = 560; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Config\Apps.json'; Sha256 = '4ae47cb48a5d927245154ca92a4c9898aa076c3b244535cadf68668d92112cfc'; Order = 9000; Kind = 'Data' }
    )
}

function Get-HunterPrivateScriptManifest {
    return @(
        Get-HunterPrivateAssetManifest |
            Where-Object { $_.Kind -eq 'Script' -and $_.RelativePath -ne 'src\Hunter\Private\Bootstrap\Loader.ps1' } |
            Sort-Object Order, RelativePath
    )
}

function Get-HunterPrivateRelativePath {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$FullName
    )

    $normalizedSourceRoot = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
    $normalizedFullName = [System.IO.Path]::GetFullPath($FullName)
    if ($normalizedFullName.StartsWith($normalizedSourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedFullName.Substring($normalizedSourceRoot.Length).TrimStart('\', '/') -replace '/', '\'
    }

    return $normalizedFullName -replace '/', '\'
}

function Test-HunterBootstrapAssetIntegrity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256 = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        return $true
    }

    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    return ($actualHash -eq $ExpectedSha256.ToLowerInvariant())
}

function Save-HunterBootstrapAsset {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RemoteRoot,
        [string]$ExpectedSha256 = ''
    )

    $destinationPath = Join-Path $SourceRoot $RelativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    if (-not (Test-Path $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    $downloadUri = '{0}/{1}' -f $RemoteRoot.TrimEnd('/'), ($RelativePath -replace '\\', '/')
    $response = Invoke-WebRequest `
        -Uri $downloadUri `
        -UseBasicParsing `
        -MaximumRedirection 10 `
        -TimeoutSec 120 `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Hunter/2.0' } `
        -ErrorAction Stop

    if ($response.Content -is [byte[]]) {
        [System.IO.File]::WriteAllBytes($destinationPath, $response.Content)
    } else {
        $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($destinationPath, [string]$response.Content, $utf8NoBomEncoding)
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actualHash = (Get-FileHash -Path $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
            throw "Integrity check failed for $RelativePath. Expected $ExpectedSha256, got $actualHash"
        }
    }
}

function Initialize-HunterPrivateSourceTree {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$RemoteRoot = '',
        [switch]$ForceRefresh
    )

    foreach ($asset in @(Get-HunterPrivateAssetManifest | Where-Object { $_.RelativePath -ne 'src\Hunter\Private\Bootstrap\Loader.ps1' })) {
        $assetPath = Join-Path $SourceRoot $asset.RelativePath
        if (-not $ForceRefresh -and (Test-Path $assetPath)) {
            if (Test-HunterBootstrapAssetIntegrity -Path $assetPath -ExpectedSha256 ([string]$asset.Sha256)) {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($RemoteRoot)) {
                throw "Hunter private asset failed integrity validation locally and no remote root is available: $($asset.RelativePath)"
            }

            Remove-Item -Path $assetPath -Force -ErrorAction SilentlyContinue
        }

        if ([string]::IsNullOrWhiteSpace($RemoteRoot)) {
            throw "Hunter private asset is missing locally and no remote root is available: $($asset.RelativePath)"
        }

        Save-HunterBootstrapAsset -SourceRoot $SourceRoot -RelativePath $asset.RelativePath -RemoteRoot $RemoteRoot -ExpectedSha256 ([string]$asset.Sha256)
    }
}

function Import-HunterPrivateScripts {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $manifest = @(Get-HunterPrivateScriptManifest)
    $orderMap = @{}
    foreach ($entry in $manifest) {
        $orderMap[[string]$entry.RelativePath] = [int]$entry.Order
    }

    $privateRoot = Join-Path $SourceRoot 'src\Hunter\Private'
    Get-ChildItem -Path $privateRoot -Recurse -Filter '*.ps1' |
        Where-Object {
            (Get-HunterPrivateRelativePath -SourceRoot $SourceRoot -FullName $_.FullName) -ne 'src\Hunter\Private\Bootstrap\Loader.ps1'
        } |
        Sort-Object `
            @{ Expression = {
                    $relativePath = Get-HunterPrivateRelativePath -SourceRoot $SourceRoot -FullName $_.FullName
                    if ($orderMap.ContainsKey($relativePath)) {
                        return $orderMap[$relativePath]
                    }

                    return [int]::MaxValue
                } },
            @{ Expression = { Get-HunterPrivateRelativePath -SourceRoot $SourceRoot -FullName $_.FullName } } |
        ForEach-Object {
            . $_.FullName
        }
}
