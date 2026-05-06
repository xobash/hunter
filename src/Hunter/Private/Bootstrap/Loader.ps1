function Get-HunterPrivateAssetManifest {
    return @(
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Bootstrap\Context.ps1'; Sha256 = '30de5ba168ec210c6b28b1c1260ddaf494999b57da471cbfa6caccdfc79aa2c0'; Order = 10; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Bootstrap\Config.ps1'; Sha256 = '032ad2392f534ea99f908937ddae466518dff56c8bf82f0bc95a7f14f628b507'; Order = 20; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Common\Common.ps1'; Sha256 = '12fe19042fcf5cd3f438202fcd37d99066d054b73d60780eedcb3a20b1a34da3'; Order = 30; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Common\PathPolicy.ps1'; Sha256 = 'f3b5a0435eca544d59d26d43deee545ac7e34495285fd6d6353c34da7d0a52bc'; Order = 40; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Infrastructure\NativeSystem.ps1'; Sha256 = 'b75b005f3c86a648c3e008380a11b48f6d3506d6a236431f634a03410d7f1d6d'; Order = 50; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Registry\Operations.ps1'; Sha256 = 'b3dc628f47f0a4cae151e100328c61f461b81007441807113bce51f8e486ca9e'; Order = 60; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\State\Rollback.ps1'; Sha256 = '0efa01c5026c086e5614f2dad7a5642a777dbb9c06e29f16474b2d67f497ca7f'; Order = 65; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Registry\UserHives.ps1'; Sha256 = 'eb860de781490d3444f2cb0ad1b86a1c3abd30e5fc6e623777c3accc316382af'; Order = 70; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Services\ServiceControl.ps1'; Sha256 = 'c2b8e5eeeedaed83822d4d2a1ecd30a42653960dbcbfcf518d3ec11cab2f8d4c'; Order = 80; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\Interaction.ps1'; Sha256 = 'ccaf9dd31e734b9978ab8aa1ea85828e86d7d315848bece4cdb2048c0ee5edf7'; Order = 90; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Crypto\LocalCredentials.ps1'; Sha256 = '2e59c50d38e729d57e195b03c0279e2f098c983730b5cafe650e764cada8608b'; Order = 100; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\Detection.ps1'; Sha256 = '9f6ddb8eca42cc715f5d24f6671e5deb9ec4d5237b8d08a5af63d2a3959664b9'; Order = 110; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\Hosts.ps1'; Sha256 = 'd5a5ee2f0a9437b36907b80c99aac9371cde9301e9685d171846331a779749ce'; Order = 120; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\PerformanceSupport.ps1'; Sha256 = '43e253fb20ce15bb11198af1c5ecc192979b84ecb2bf36392d02771d750bb6b0'; Order = 130; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\System\PerformanceTuning.ps1'; Sha256 = '298cef16037960c27d6121ca89d88d2c1aa36b78ef4a6602ca88b09d667632f7'; Order = 140; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Shortcuts\PathManagement.ps1'; Sha256 = 'a9a136791badf5b1c9be88cbd074ace465a16cae4a8361442774621b489126ec'; Order = 150; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Shortcuts\ShortcutOps.ps1'; Sha256 = 'ae02086f48acfe2ff786a9e3c77e08b710e6bddaba131a67ad61413eb5db3ead'; Order = 160; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Shortcuts\TaskbarOps.ps1'; Sha256 = '4bfc698c21f73e599a886b91126a7885e61ae9d1aec22cdbf25ec456a4c5e256'; Order = 170; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Gpu\GpuTuning.ps1'; Sha256 = '96ff9277e01805c39c38342c1d794d80404d90723446af604a395c6129974263'; Order = 180; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Apps\AppCatalog.ps1'; Sha256 = '302d4c02f53407d15b202b70725beb88157963ed84966a3271571e8c7ae54fce'; Order = 190; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Apps\AppRemoval.ps1'; Sha256 = '61b407e2ec2b1c71d8ff1ad19f340467a644cb34da59a75208e10a7664270917'; Order = 200; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Apps\AppxRemoval.ps1'; Sha256 = '5bc498767b84a41825ab7e2e418c5b0743f10e921247341d90390a4818b5e42c'; Order = 210; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Registry.ps1'; Sha256 = '64940f4679c1e3ad5739851461b5f3c5f0ff1bbbb3cd8214903fdb895ff15f72'; Order = 220; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Validation.ps1'; Sha256 = '2c1bafd0d294b7c87e4df2966cb586ab09eea53b815b999b842750130cb57be0'; Order = 230; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Downloads\Prefetch.ps1'; Sha256 = 'a32a75e0404219a96cf18d24d9b32f6a31110f2be49df01fd57753d7ed57b69b'; Order = 240; Kind = 'Script' }
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
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Helpers.ps1'; Sha256 = '613811923e4b5c9375eb2946ab7edc5b291d7fae28053b30511850696b8a157c'; Order = 370; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Winget.ps1'; Sha256 = '39504da585ece61d487d907471a9a0f8190ad1a0846c6b31b26fea211c8aed7c'; Order = 380; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Catalog.ps1'; Sha256 = '4ff948d0e267443c66085977d8cb710f914d1f697cdc5efa6ea2a2b8c9d8dd93'; Order = 390; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Packages\Installer.ps1'; Sha256 = 'ceba11f5c633e664f28ff3c51cf33e28a607a4c6ef54f573b78fce67b7a1df42'; Order = 400; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\UI\ProgressWindow.ps1'; Sha256 = 'ead92fd16f855a9218e87e11404288b87ee563bb43bca4d032adbf6f3b698413'; Order = 410; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\UI\ExplorerOps.ps1'; Sha256 = 'f10ecc0020fd4e8f6376e402c5d516387f6c03227bed48cf8292a10efabc67b1'; Order = 420; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Preflight.ps1'; Sha256 = '73af899b401d6883a1b51b24c65ef4742d16fe3a5a7c743c8addb0e0942671fa'; Order = 430; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Core\UserSetup.ps1'; Sha256 = '27d06a57770e37de1a756ef714f69d745737b838239af44facd079c5ac0253e2'; Order = 440; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\UI.ps1'; Sha256 = '4249b15613f4dcda460a51d2e6b25b2c25173099b1f3e9d8f388b3dec1ff8225'; Order = 450; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Explorer.ps1'; Sha256 = '99f5b5964ee357f1e6a71633b1b377c556ab9e88672c20c281fcaceafef064ab'; Order = 460; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Edge.ps1'; Sha256 = '57c6fc8db525e601243915cf20c2426dd0d23af6ae30448fb2452ef7037196b5'; Order = 470; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\OneDriveCopilot.ps1'; Sha256 = '5965bead80668f915532eec80825a9297ac6cfe1b388a9f70bb45585923c7a77'; Order = 480; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Specialized.ps1'; Sha256 = '5ef66c186588d276d64bd14d746c2e412cc68b9cda0faa7616be8b227c85118b'; Order = 490; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Privacy.ps1'; Sha256 = 'd0b2d59fa540967a24551a925feac0e299deba96470d5dd262d2b4e836768c13'; Order = 500; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Features.ps1'; Sha256 = 'd7dda6dc9710d94568e04c94661aaa29db37c37a0d1137dd1bb6d6a5af247a53'; Order = 510; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Tweaks\Hardware.ps1'; Sha256 = '95a68a5b848465ee58af735c45ec85f2acb4fa26a0ab8e87e358b1ac00e23ead'; Order = 520; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Cleanup.ps1'; Sha256 = '7c3bbdf8a3e06573c91ffa757880dd7221590fa4839b3df955cb69fa276f692f'; Order = 530; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Tasks\Catalog.ps1'; Sha256 = 'a0be0243381e72ed292bc3ea8c685b713109e710ad5faff74de99b9d4f313b7f'; Order = 540; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Execution\Engine.ps1'; Sha256 = '692d4a9140e60e4e4407de7e0a89b6fa2b9013583ed0e90b53fbfc8834513a44'; Order = 550; Kind = 'Script' }
        [pscustomobject]@{ RelativePath = 'src\Hunter\Private\Execution\Resume.ps1'; Sha256 = '5a2c4ae039a973dccc6c4e99285981f5e71eb5b19f4989c80d68bc8f16af0fee'; Order = 560; Kind = 'Script' }
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
            throw "Integrity check failed for ${RelativePath}. Expected ${ExpectedSha256}, got ${actualHash}"
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
