function Add-HostsEntries {
    param([string[]]$Hostnames)
    if ($null -eq $Hostnames -or $Hostnames.Count -eq 0) { return }

    try {
        $hostsFile = $script:HostsFilePath
        $existingContent = @()
        if (Test-Path $hostsFile) {
            $existingContent = @(Get-Content -Path $hostsFile -ErrorAction SilentlyContinue)
        }

        $newEntries = @()
        foreach ($hostname in $Hostnames) {
            $entry = "0.0.0.0 $hostname"
            if ($existingContent -notcontains $entry) {
                $newEntries += $entry
                Write-Log "Hosts entry queued: $entry"
            }
        }

        if ($newEntries.Count -gt 0) {
            Add-Content -Path $hostsFile -Value ($newEntries -join "`n")
            Write-Log "Hosts file updated with $($newEntries.Count) new entries."
        }
    } catch {
        Write-Log "Failed to batch-update hosts file: $_" 'ERROR'
    }
}
