function Invoke-SetExplorerHomeThisPC {
    if (Test-TaskCompleted -TaskId 'explorer-home-thispc') {
        Write-Log "Explorer home already set to This PC, skipping"
        return (New-TaskSkipResult -Reason 'Explorer home is already set to This PC')
    }

    try {
        $advPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        Set-RegistryValue -Path $advPath -Name 'LaunchTo' -Value 1 -Type 'DWord'

        return $true
    } catch {
        Write-Log "Failed to set Explorer home to This PC : $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveExplorerHomeTab {
    try {
        $homeGuid = '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'
        Remove-ExplorerNamespaceAndVerify -Guid $homeGuid -DisplayName 'Home'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to remove Explorer Home tab : $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveExplorerGalleryTab {
    try {
        $galleryGuid = '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'
        Remove-ExplorerNamespaceAndVerify -Guid $galleryGuid -DisplayName 'Gallery'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to remove Explorer Gallery tab : $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveExplorerOneDriveTab {
    if (Test-TaskCompleted -TaskId 'explorer-remove-onedrive') {
        Write-Log "Explorer OneDrive tab already removed, skipping"
        return (New-TaskSkipResult -Reason 'Explorer OneDrive tab is already removed')
    }

    try {
        $oneDriveGuid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
        Remove-ExplorerNamespaceAndVerify -Guid $oneDriveGuid -DisplayName 'OneDrive'

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to remove Explorer OneDrive tab : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableExplorerAutoFolderDiscovery {
    if (Test-TaskCompleted -TaskId 'explorer-auto-discovery') {
        Write-Log "Explorer auto folder discovery already disabled, skipping"
        return (New-TaskSkipResult -Reason 'Explorer auto folder discovery is already disabled')
    }

    try {
        $bagsPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
        $bagMRUPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
        $shellPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'

        Remove-RegistryKey -Path $bagsPath
        Remove-RegistryKey -Path $bagMRUPath

        Set-RegistryValue -Path $shellPath -Name 'FolderType' -Value 'NotSpecified' -Type String

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to disable Explorer auto folder discovery : $_" 'ERROR'
        return $false
    }
}
