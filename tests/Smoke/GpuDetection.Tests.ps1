Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'GPU detection behavior' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        . (Join-Path $repoRoot 'src/Hunter/Private/Gpu/GpuTuning.ps1')
    }

    BeforeEach {
        function Write-Log {
            param(
                [string]$Message,
                [string]$Level = 'INFO'
            )
        }
    }

    It 'falls back to alternate registry properties when FriendlyName is absent' {
        $vendorPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\PCI\VEN_1414&DEV_008E'
        $instancePath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\PCI\VEN_1414&DEV_008E\5&140a0744&0&0'

        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' }
        Mock Get-ChildItem {
            param([string]$Path)

            switch ($Path) {
                'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' {
                    return [pscustomobject]@{
                        PSPath = $vendorPath
                    }
                }
                $vendorPath {
                    return [pscustomobject]@{
                        PSPath = $instancePath
                        PSChildName = '5&140a0744&0&0'
                    }
                }
                default {
                    return @()
                }
            }
        }
        Mock Get-ItemProperty {
            [pscustomobject]@{
                ClassGUID = '{4d36e968-e325-11ce-bfc1-08002be10318}'
                DeviceDesc = 'Microsoft Hyper-V Video'
                HardwareID = @('PCI\VEN_1414&DEV_008E')
            }
        } -ParameterFilter { $Path -eq $instancePath }
        Mock Write-Log {}

        { @(Get-GpuPciDeviceContexts) } | Should -Not -Throw

        $gpuContexts = @(Get-GpuPciDeviceContexts)
        $gpuContexts.Count | Should -Be 1
        $gpuContexts[0].Name | Should -BeExactly 'Microsoft Hyper-V Video'
        $gpuContexts[0].Vendor | Should -BeExactly 'Unknown'
        $gpuContexts[0].PciInstanceId | Should -BeExactly '5&140a0744&0&0'
        Assert-MockCalled Write-Log -Times 0 -ParameterFilter {
            $Message -like 'Failed to inspect PCI display device*' -and $Level -eq 'WARN'
        }
    }
}
