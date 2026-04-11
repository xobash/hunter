function Show-YesNoDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [bool]$DefaultToNo = $true
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $defaultButton = if ($DefaultToNo) {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        } else {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        }

        $dialogResult = [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            $defaultButton
        )

        return ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        Add-RunInfrastructureIssue -Message "Failed to show confirmation dialog '$Title': $($_.Exception.Message). Defaulting to No." -Level 'WARN'
        return $false
    }
}

function Resolve-SkipAppDownloadsPreference {
    if ($null -ne $script:SkipAppDownloads) {
        return [bool]$script:SkipAppDownloads
    }

    if ($script:IsAutomationRun) {
        $script:SkipAppDownloads = $false
        return $false
    }

    $script:SkipAppDownloads = Show-YesNoDialog `
        -Title 'Hunter App Downloads' `
        -Message "Skip app downloads and installs?`n`nChoose Yes to skip package downloads and installs, or No to continue with the normal app download and install pipeline." `
        -DefaultToNo $true

    if ($script:SkipAppDownloads) {
        Write-Log 'App downloads and installs skipped by user.' 'INFO'
    } else {
        Write-Log 'App downloads and installs enabled by user.' 'INFO'
    }

    return [bool]$script:SkipAppDownloads
}

