function Enable-GlobalTimerResolutionRequests {
    param([switch]$LogIfAlreadyEnabled)

    $kernelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    if (-not (Test-RegistryValue -Path $kernelPath -Name 'GlobalTimerResolutionRequests' -ExpectedValue 1)) {
        Set-RegistryValue -Path $kernelPath -Name 'GlobalTimerResolutionRequests' -Value 1 -Type DWord
        return $true
    }

    if ($LogIfAlreadyEnabled) {
        Write-Log 'Global timer resolution requests already enabled.' 'INFO'
    }

    return $false
}
