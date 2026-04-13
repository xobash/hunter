$script:RollbackManifestSchemaVersion = 1
$script:RollbackEntries = @()
$script:RollbackEntryIndex = @{}

function ConvertTo-HunterPowerShellLiteral {
    param([object]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { '$true' } else { '$false' })
    }

    if ($Value -is [byte[]]) {
        return ('([byte[]]@({0}))' -f ((@($Value) | ForEach-Object { [string]$_ }) -join ', '))
    }

    if (($Value -is [System.Array]) -and -not ($Value -is [byte[]])) {
        return ('@({0})' -f ((@($Value) | ForEach-Object { ConvertTo-HunterPowerShellLiteral -Value $_ }) -join ', '))
    }

    if ($Value -is [ValueType]) {
        return ([string]$Value)
    }

    return ("'{0}'" -f ([string]$Value).Replace("'", "''"))
}

function ConvertTo-HunterRegistryProviderLiteral {
    param([Parameter(Mandatory)][string]$Path)

    return ("'{0}'" -f $Path.Replace("'", "''"))
}

function ConvertTo-HunterRegistryNativePath {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -like 'HKLM:\*') {
        return ('HKLM\{0}' -f $Path.Substring(6))
    }

    if ($Path -like 'HKCU:\*') {
        return ('HKCU\{0}' -f $Path.Substring(6))
    }

    if ($Path -like 'HKU:\*') {
        return ('HKU\{0}' -f $Path.Substring(5))
    }

    if ($Path -like 'Registry::HKEY_LOCAL_MACHINE\*') {
        return ('HKLM\{0}' -f $Path.Substring(29))
    }

    if ($Path -like 'Registry::HKEY_CURRENT_USER\*') {
        return ('HKCU\{0}' -f $Path.Substring(28))
    }

    if ($Path -like 'Registry::HKEY_USERS\*') {
        return ('HKU\{0}' -f $Path.Substring(21))
    }

    return $Path
}

function Resolve-HunterRollbackDefaultUserHivePath {
    $defaultHive = $null
    try {
        $profileListDefault = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name Default -ErrorAction SilentlyContinue).Default
        if (-not [string]::IsNullOrWhiteSpace([string]$profileListDefault)) {
            $defaultHive = Join-Path $profileListDefault 'NTUSER.DAT'
        }
    } catch {
        $defaultHive = $null
    }

    if ([string]::IsNullOrWhiteSpace([string]$defaultHive) -or -not (Test-Path $defaultHive)) {
        $fallbackHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        if (Test-Path $fallbackHive) {
            $defaultHive = $fallbackHive
        }
    }

    return $defaultHive
}

function Get-HunterRollbackManifestPayload {
    return [ordered]@{
        SchemaVersion = [int]$script:RollbackManifestSchemaVersion
        GeneratedAt   = (Get-Date).ToString('o')
        Entries       = @($script:RollbackEntries)
    }
}

function Save-HunterRollbackManifest {
    if ([string]::IsNullOrWhiteSpace($script:RollbackRoot) -or [string]::IsNullOrWhiteSpace($script:RollbackManifestPath)) {
        return
    }

    Initialize-HunterDirectory $script:RollbackRoot
    $payload = Get-HunterRollbackManifestPayload
    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $script:RollbackManifestPath -Encoding UTF8 -Force
}

function Export-HunterRollbackScript {
    if ([string]::IsNullOrWhiteSpace($script:RollbackRoot) -or [string]::IsNullOrWhiteSpace($script:RollbackScriptPath)) {
        return
    }

    Initialize-HunterDirectory $script:RollbackRoot

    $scriptLines = @(
        '#Requires -RunAsAdministrator',
        '$ErrorActionPreference = ''Stop''',
        '',
        'function Invoke-HunterRestoreStep {',
        '    param(',
        '        [Parameter(Mandatory)][string]$Description,',
        '        [Parameter(Mandatory)][scriptblock]$Action',
        '    )',
        '',
        '    try {',
        '        & $Action',
        '        Write-Host ("[RESTORE] {0}" -f $Description) -ForegroundColor Green',
        '    } catch {',
        '        Write-Warning ("Restore step failed: {0} - {1}" -f $Description, $_.Exception.Message)',
        '    }',
        '}',
        '',
        'function Set-HunterRegistryValue {',
        '    param(',
        '        [Parameter(Mandatory)][string]$Path,',
        '        [Parameter(Mandatory)][string]$Name,',
        '        [Parameter(Mandatory)][object]$Value,',
        '        [Parameter(Mandatory)][string]$Type',
        '    )',
        '',
        '    if (-not (Test-Path $Path)) {',
        '        New-Item -Path $Path -Force | Out-Null',
        '    }',
        '',
        '    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null',
        '}',
        '',
        'function Remove-HunterRegistryValue {',
        '    param(',
        '        [Parameter(Mandatory)][string]$Path,',
        '        [Parameter(Mandatory)][string]$Name',
        '    )',
        '',
        '    if (Test-Path $Path) {',
        '        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue',
        '    }',
        '}',
        '',
        'function Set-HunterRegistryDefaultValue {',
        '    param(',
        '        [Parameter(Mandatory)][string]$Path,',
        '        [AllowNull()][object]$Value',
        '    )',
        '',
        '    if (-not (Test-Path $Path)) {',
        '        New-Item -Path $Path -Force | Out-Null',
        '    }',
        '',
        '    Set-Item -Path $Path -Value $Value',
        '}',
        '',
        'function Remove-HunterRegistryDefaultValue {',
        '    param([Parameter(Mandatory)][string]$NativePath)',
        '',
        '    & reg.exe delete $NativePath /ve /f *> $null',
        '}',
        '',
        'function Get-HunterDefaultUserHivePath {',
        '    $defaultHive = $null',
        '    try {',
        '        $profileListDefault = (Get-ItemProperty ''HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'' -Name Default -ErrorAction SilentlyContinue).Default',
        '        if (-not [string]::IsNullOrWhiteSpace([string]$profileListDefault)) {',
        '            $defaultHive = Join-Path $profileListDefault ''NTUSER.DAT''',
        '        }',
        '    } catch {',
        '        $defaultHive = $null',
        '    }',
        '',
        '    if ([string]::IsNullOrWhiteSpace([string]$defaultHive) -or -not (Test-Path $defaultHive)) {',
        '        $fallbackHive = Join-Path $env:SystemDrive ''Users\Default\NTUSER.DAT''',
        '        if (Test-Path $fallbackHive) {',
        '            $defaultHive = $fallbackHive',
        '        }',
        '    }',
        '',
        '    return $defaultHive',
        '}',
        '',
        'function Invoke-WithHunterDefaultUserHive {',
        '    param([Parameter(Mandatory)][scriptblock]$Action)',
        '',
        '    $defaultHive = Get-HunterDefaultUserHivePath',
        '    if ([string]::IsNullOrWhiteSpace([string]$defaultHive) -or -not (Test-Path $defaultHive)) {',
        '        throw ''Default user hive was not found.''',
        '    }',
        '',
        '    & reg.exe load ''HKU\HunterDefaultRestore'' $defaultHive *> $null',
        '    if ([int]$LASTEXITCODE -ne 0) {',
        '        throw ''Failed to load the Default user hive for restore.''',
        '    }',
        '',
        '    try {',
        '        & $Action',
        '    } finally {',
        '        [GC]::Collect()',
        '        & reg.exe unload ''HKU\HunterDefaultRestore'' *> $null',
        '    }',
        '}',
        '',
        'function Set-HunterDefaultUserRegistryValue {',
        '    param(',
        '        [Parameter(Mandatory)][string]$SubPath,',
        '        [Parameter(Mandatory)][string]$Name,',
        '        [Parameter(Mandatory)][object]$Value,',
        '        [Parameter(Mandatory)][string]$Type',
        '    )',
        '',
        '    Invoke-WithHunterDefaultUserHive -Action {',
        '        $path = "Registry::HKEY_USERS\HunterDefaultRestore\$SubPath"',
        '        if (-not (Test-Path $path)) {',
        '            New-Item -Path $path -Force | Out-Null',
        '        }',
        '',
        '        New-ItemProperty -Path $path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null',
        '    }',
        '}',
        '',
        'function Remove-HunterDefaultUserRegistryValue {',
        '    param(',
        '        [Parameter(Mandatory)][string]$SubPath,',
        '        [Parameter(Mandatory)][string]$Name',
        '    )',
        '',
        '    Invoke-WithHunterDefaultUserHive -Action {',
        '        $path = "Registry::HKEY_USERS\HunterDefaultRestore\$SubPath"',
        '        if (Test-Path $path) {',
        '            Remove-ItemProperty -Path $path -Name $Name -Force -ErrorAction SilentlyContinue',
        '        }',
        '    }',
        '}',
        '',
        'function Set-HunterDefaultUserRegistryDefaultValue {',
        '    param(',
        '        [Parameter(Mandatory)][string]$SubPath,',
        '        [AllowNull()][object]$Value',
        '    )',
        '',
        '    Invoke-WithHunterDefaultUserHive -Action {',
        '        $path = "Registry::HKEY_USERS\HunterDefaultRestore\$SubPath"',
        '        if (-not (Test-Path $path)) {',
        '            New-Item -Path $path -Force | Out-Null',
        '        }',
        '',
        '        Set-Item -Path $path -Value $Value',
        '    }',
        '}',
        '',
        'function Remove-HunterDefaultUserRegistryDefaultValue {',
        '    param([Parameter(Mandatory)][string]$SubPath)',
        '',
        '    Invoke-WithHunterDefaultUserHive -Action {',
        '        $nativePath = "HKU\HunterDefaultRestore\$SubPath"',
        '        & reg.exe delete $nativePath /ve /f *> $null',
        '    }',
        '}',
        '',
        'function Restore-HunterServiceStartType {',
        '    param(',
        '        [Parameter(Mandatory)][string]$Name,',
        '        [Parameter(Mandatory)][string]$StartMode',
        '    )',
        '',
        '    $startValue = switch ($StartMode) {',
        '        ''Boot'' { 0 }',
        '        ''System'' { 1 }',
        '        ''Auto'' { 2 }',
        '        ''Automatic'' { 2 }',
        '        ''Manual'' { 3 }',
        '        ''Disabled'' { 4 }',
        '        default { 3 }',
        '    }',
        '',
        '    $serviceKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"',
        '    if (-not (Test-Path $serviceKeyPath)) {',
        '        return',
        '    }',
        '',
        '    Set-ItemProperty -Path $serviceKeyPath -Name ''Start'' -Value $startValue -Force',
        '}',
        '',
        'function Restore-HunterScheduledTaskState {',
        '    param(',
        '        [Parameter(Mandatory)][string]$TaskPath,',
        '        [Parameter(Mandatory)][string]$TaskName,',
        '        [Parameter(Mandatory)][bool]$Disabled',
        '    )',
        '',
        '    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue',
        '    if ($null -eq $task) {',
        '        return',
        '    }',
        '',
        '    if ($Disabled) {',
        '        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null',
        '    } else {',
        '        Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null',
        '    }',
        '}',
        '',
        'Write-Host ''Restoring Hunter-recorded system settings...'' -ForegroundColor Cyan',
        ''
    )

    foreach ($entry in @($script:RollbackEntries)) {
        foreach ($line in @($entry.RestoreLines)) {
            $scriptLines += [string]$line
        }
        $scriptLines += ''
    }

    $scriptLines += @(
        'Write-Host ''Hunter restore script finished. Review warnings above for any best-effort steps that could not be restored automatically.'' -ForegroundColor Cyan',
        ''
    )

    Set-Content -Path $script:RollbackScriptPath -Value $scriptLines -Encoding UTF8 -Force
}

function Initialize-HunterRollbackState {
    param(
        [ValidateSet('Execute', 'Resume')]
        [string]$Mode = 'Execute'
    )

    $script:RollbackEntries = @()
    $script:RollbackEntryIndex = @{}

    Initialize-HunterDirectory $script:RollbackRoot

    if ($Mode -eq 'Resume' -and (Test-Path $script:RollbackManifestPath)) {
        try {
            $manifest = Get-Content -Path $script:RollbackManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($entry in @($manifest.Entries)) {
                if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Key)) {
                    continue
                }

                $script:RollbackEntries += [pscustomobject]@{
                    Key          = [string]$entry.Key
                    Category     = [string]$entry.Category
                    Description  = [string]$entry.Description
                    RestoreLines = @($entry.RestoreLines | ForEach-Object { [string]$_ })
                }
                $script:RollbackEntryIndex[[string]$entry.Key] = $true
            }

            Export-HunterRollbackScript
            return
        } catch {
            Write-Log "Failed to load persisted rollback manifest: $($_.Exception.Message)" 'WARN'
        }
    }

    Save-HunterRollbackManifest
    Export-HunterRollbackScript
}

function Register-HunterRollbackEntry {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$RestoreLines,
        [string]$Category = 'General'
    )

    if ([string]::IsNullOrWhiteSpace($Key) -or $script:RollbackEntryIndex.ContainsKey($Key)) {
        return
    }

    $entry = [pscustomobject]@{
        Key          = $Key
        Category     = $Category
        Description  = $Description
        RestoreLines = @($RestoreLines)
    }

    $script:RollbackEntries += $entry
    $script:RollbackEntryIndex[$Key] = $true
    Save-HunterRollbackManifest
    Export-HunterRollbackScript
}

function Register-HunterManualRestoreNote {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Description,
        [string[]]$Instructions = @()
    )

    if ($script:RollbackEntryIndex.ContainsKey($Key)) {
        return
    }

    $restoreLines = @()
    foreach ($instruction in @($Instructions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $restoreLines += ("Write-Warning '{0}'" -f ([string]$instruction).Replace("'", "''"))
    }

    if ($restoreLines.Count -eq 0) {
        return
    }

    Register-HunterRollbackEntry -Key $Key -Category 'ManualRestore' -Description $Description -RestoreLines $restoreLines
}

function Get-HunterRegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $snapshot = [ordered]@{
        Exists = $false
        Value  = $null
        Type   = $null
    }

    try {
        if (-not (Test-Path $Path)) {
            return [pscustomobject]$snapshot
        }

        $registryKey = Get-Item -Path $Path -ErrorAction Stop
        $valueName = [string]$Name
        $existingValueNames = @($registryKey.GetValueNames())
        $hasValue = $existingValueNames -contains $valueName
        if (-not $hasValue) {
            return [pscustomobject]$snapshot
        }

        $snapshot.Exists = $true
        $snapshot.Value = $registryKey.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $snapshot.Type = [string]$registryKey.GetValueKind($valueName)
        return [pscustomobject]$snapshot
    } catch {
        Write-Log "Failed to capture registry rollback snapshot for $Path\$Name : $($_.Exception.Message)" 'WARN'
        return [pscustomobject]$snapshot
    }
}

function Get-HunterRegistryDefaultValueSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $snapshot = [ordered]@{
        Exists = $false
        Value  = $null
    }

    try {
        if (-not (Test-Path $Path)) {
            return [pscustomobject]$snapshot
        }

        $registryKey = Get-Item -Path $Path -ErrorAction Stop
        $existingValueNames = @($registryKey.GetValueNames())
        $hasDefaultValue = $existingValueNames -contains ''
        if (-not $hasDefaultValue) {
            return [pscustomobject]$snapshot
        }

        $snapshot.Exists = $true
        $snapshot.Value = $registryKey.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]$snapshot
    } catch {
        Write-Log "Failed to capture registry default-value rollback snapshot for $Path : $($_.Exception.Message)" 'WARN'
        return [pscustomobject]$snapshot
    }
}

function Get-HunterDefaultUserRegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string]$SubPath,
        [Parameter(Mandatory)][string]$Name
    )

    $defaultHive = Resolve-HunterRollbackDefaultUserHivePath
    if ([string]::IsNullOrWhiteSpace([string]$defaultHive) -or -not (Test-Path $defaultHive)) {
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
            Type   = $null
        }
    }

    $hiveName = 'HKU\HunterRollbackDefault'
    try {
        if (-not (Invoke-RegHiveCommandWithRetry -Action Load -HiveName $hiveName -HivePath $defaultHive)) {
            throw 'Failed to load the Default user hive.'
        }

        $hiveRoot = Resolve-RegistryHivePath -HiveName $hiveName
        return (Get-HunterRegistryValueSnapshot -Path "$hiveRoot\$SubPath" -Name $Name)
    } catch {
        Write-Log "Failed to capture Default user registry rollback snapshot for $SubPath\$Name : $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
            Type   = $null
        }
    } finally {
        [GC]::Collect()
        Invoke-RegHiveCommandWithRetry -Action Unload -HiveName $hiveName | Out-Null
    }
}

function Get-HunterDefaultUserRegistryDefaultValueSnapshot {
    param([Parameter(Mandatory)][string]$SubPath)

    $defaultHive = Resolve-HunterRollbackDefaultUserHivePath
    if ([string]::IsNullOrWhiteSpace([string]$defaultHive) -or -not (Test-Path $defaultHive)) {
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
        }
    }

    $hiveName = 'HKU\HunterRollbackDefault'
    try {
        if (-not (Invoke-RegHiveCommandWithRetry -Action Load -HiveName $hiveName -HivePath $defaultHive)) {
            throw 'Failed to load the Default user hive.'
        }

        $hiveRoot = Resolve-RegistryHivePath -HiveName $hiveName
        return (Get-HunterRegistryDefaultValueSnapshot -Path "$hiveRoot\$SubPath")
    } catch {
        Write-Log "Failed to capture Default user registry default-value rollback snapshot for $SubPath : $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
        }
    } finally {
        [GC]::Collect()
        Invoke-RegHiveCommandWithRetry -Action Unload -HiveName $hiveName | Out-Null
    }
}

function Register-HunterRegistryValueRollback {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $key = 'registry-value|{0}|{1}' -f $Path.ToLowerInvariant(), $Name
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    $snapshot = Get-HunterRegistryValueSnapshot -Path $Path -Name $Name
    $pathLiteral = ConvertTo-HunterRegistryProviderLiteral -Path $Path
    $nameLiteral = ("'{0}'" -f $Name.Replace("'", "''"))
    $restoreLines = if ([bool]$snapshot.Exists) {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Set-HunterRegistryValue -Path {1} -Name {2} -Value {3} -Type {4} }}' -f
                ("'Restore registry value {0}\{1}'" -f $Path.Replace("'", "''"), $Name.Replace("'", "''")),
                $pathLiteral,
                $nameLiteral,
                (ConvertTo-HunterPowerShellLiteral -Value $snapshot.Value),
                ("'{0}'" -f ([string]$snapshot.Type).Replace("'", "''")))
        )
    } else {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Remove-HunterRegistryValue -Path {1} -Name {2} }}' -f
                ("'Remove registry value {0}\{1}'" -f $Path.Replace("'", "''"), $Name.Replace("'", "''")),
                $pathLiteral,
                $nameLiteral)
        )
    }

    Register-HunterRollbackEntry -Key $key -Category 'Registry' -Description "Registry value $Path\$Name" -RestoreLines $restoreLines
}

function Register-HunterRegistryDefaultValueRollback {
    param([Parameter(Mandatory)][string]$Path)

    $key = 'registry-default|{0}' -f $Path.ToLowerInvariant()
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    $snapshot = Get-HunterRegistryDefaultValueSnapshot -Path $Path
    $pathLiteral = ConvertTo-HunterRegistryProviderLiteral -Path $Path
    $nativePathLiteral = ("'{0}'" -f ((ConvertTo-HunterRegistryNativePath -Path $Path).Replace("'", "''")))
    $restoreLines = if ([bool]$snapshot.Exists) {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Set-HunterRegistryDefaultValue -Path {1} -Value {2} }}' -f
                ("'Restore registry default value {0}'" -f $Path.Replace("'", "''")),
                $pathLiteral,
                (ConvertTo-HunterPowerShellLiteral -Value $snapshot.Value))
        )
    } else {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Remove-HunterRegistryDefaultValue -NativePath {1} }}' -f
                ("'Remove registry default value {0}'" -f $Path.Replace("'", "''")),
                $nativePathLiteral)
        )
    }

    Register-HunterRollbackEntry -Key $key -Category 'Registry' -Description "Registry default value $Path" -RestoreLines $restoreLines
}

function Register-HunterDefaultUserRegistryValueRollback {
    param(
        [Parameter(Mandatory)][string]$SubPath,
        [Parameter(Mandatory)][string]$Name
    )

    $key = 'default-user-registry-value|{0}|{1}' -f $SubPath.ToLowerInvariant(), $Name
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    $snapshot = Get-HunterDefaultUserRegistryValueSnapshot -SubPath $SubPath -Name $Name
    $subPathLiteral = ("'{0}'" -f $SubPath.Replace("'", "''"))
    $nameLiteral = ("'{0}'" -f $Name.Replace("'", "''"))
    $restoreLines = if ([bool]$snapshot.Exists) {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Set-HunterDefaultUserRegistryValue -SubPath {1} -Name {2} -Value {3} -Type {4} }}' -f
                ("'Restore Default user registry value {0}\{1}'" -f $SubPath.Replace("'", "''"), $Name.Replace("'", "''")),
                $subPathLiteral,
                $nameLiteral,
                (ConvertTo-HunterPowerShellLiteral -Value $snapshot.Value),
                ("'{0}'" -f ([string]$snapshot.Type).Replace("'", "''")))
        )
    } else {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Remove-HunterDefaultUserRegistryValue -SubPath {1} -Name {2} }}' -f
                ("'Remove Default user registry value {0}\{1}'" -f $SubPath.Replace("'", "''"), $Name.Replace("'", "''")),
                $subPathLiteral,
                $nameLiteral)
        )
    }

    Register-HunterRollbackEntry -Key $key -Category 'Registry' -Description "Default user registry value $SubPath\$Name" -RestoreLines $restoreLines
}

function Register-HunterDefaultUserRegistryDefaultValueRollback {
    param([Parameter(Mandatory)][string]$SubPath)

    $key = 'default-user-registry-default|{0}' -f $SubPath.ToLowerInvariant()
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    $snapshot = Get-HunterDefaultUserRegistryDefaultValueSnapshot -SubPath $SubPath
    $subPathLiteral = ("'{0}'" -f $SubPath.Replace("'", "''"))
    $restoreLines = if ([bool]$snapshot.Exists) {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Set-HunterDefaultUserRegistryDefaultValue -SubPath {1} -Value {2} }}' -f
                ("'Restore Default user registry default value {0}'" -f $SubPath.Replace("'", "''")),
                $subPathLiteral,
                (ConvertTo-HunterPowerShellLiteral -Value $snapshot.Value))
        )
    } else {
        @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ Remove-HunterDefaultUserRegistryDefaultValue -SubPath {1} }}' -f
                ("'Remove Default user registry default value {0}'" -f $SubPath.Replace("'", "''")),
                $subPathLiteral)
        )
    }

    Register-HunterRollbackEntry -Key $key -Category 'Registry' -Description "Default user registry default value $SubPath" -RestoreLines $restoreLines
}

function Get-HunterServiceStartModeSnapshot {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $escapedName = $Name.Replace("'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return $null
        }

        return [string]$service.StartMode
    } catch {
        Write-Log "Failed to capture service rollback snapshot for ${Name}: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Register-HunterServiceStartTypeRollback {
    param([Parameter(Mandatory)][string]$Name)

    $key = 'service-start-type|{0}' -f $Name.ToLowerInvariant()
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    $startMode = Get-HunterServiceStartModeSnapshot -Name $Name
    if ([string]::IsNullOrWhiteSpace($startMode)) {
        return
    }

    $restoreLines = @(
        ('Invoke-HunterRestoreStep -Description {0} -Action {{ Restore-HunterServiceStartType -Name {1} -StartMode {2} }}' -f
            ("'Restore service start type {0}'" -f $Name.Replace("'", "''")),
            ("'{0}'" -f $Name.Replace("'", "''")),
            ("'{0}'" -f $startMode.Replace("'", "''")))
    )

    Register-HunterRollbackEntry -Key $key -Category 'Service' -Description "Service startup type $Name" -RestoreLines $restoreLines
}

function Get-HunterScheduledTaskDisabledSnapshot {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return $null
        }

        return ([string]$task.State -eq 'Disabled')
    } catch {
        Write-Log "Failed to capture scheduled-task rollback snapshot for ${TaskPath}${TaskName}: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Register-HunterScheduledTaskRollback {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $key = 'scheduled-task-state|{0}|{1}' -f $TaskPath.ToLowerInvariant(), $TaskName.ToLowerInvariant()
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    $wasDisabled = Get-HunterScheduledTaskDisabledSnapshot -TaskPath $TaskPath -TaskName $TaskName
    if ($null -eq $wasDisabled) {
        return
    }

    $restoreLines = @(
        ('Invoke-HunterRestoreStep -Description {0} -Action {{ Restore-HunterScheduledTaskState -TaskPath {1} -TaskName {2} -Disabled:{3} }}' -f
            ("'Restore scheduled task state {0}{1}'" -f $TaskPath.Replace("'", "''"), $TaskName.Replace("'", "''")),
            ("'{0}'" -f $TaskPath.Replace("'", "''")),
            ("'{0}'" -f $TaskName.Replace("'", "''")),
            $(if ([bool]$wasDisabled) { '$true' } else { '$false' }))
    )

    Register-HunterRollbackEntry -Key $key -Category 'ScheduledTask' -Description "Scheduled task state $TaskPath$TaskName" -RestoreLines $restoreLines
}

function Register-HunterActivePowerSchemeRollback {
    $key = 'powercfg-active-scheme'
    if ($script:RollbackEntryIndex.ContainsKey($key)) {
        return
    }

    try {
        $activeSchemeOutput = @(& powercfg.exe /getactivescheme 2>$null)
        $guidPattern = [regex]'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        $activeSchemeGuid = $null
        foreach ($line in $activeSchemeOutput) {
            $match = $guidPattern.Match([string]$line)
            if ($match.Success) {
                $activeSchemeGuid = $match.Value
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($activeSchemeGuid)) {
            return
        }

        Initialize-HunterDirectory $script:RollbackRoot
        $backupPath = Join-Path $script:RollbackRoot ("power-scheme-{0}.pow" -f $activeSchemeGuid.ToLowerInvariant())
        if (-not (Test-Path $backupPath)) {
            Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/export', $backupPath, $activeSchemeGuid) | Out-Null
        }

        $restoreLines = @(
            ('Invoke-HunterRestoreStep -Description {0} -Action {{ & powercfg.exe /import {1} {2} *> $null; & powercfg.exe /setactive {2} *> $null }}' -f
                ("'Restore original active power scheme {0}'" -f $activeSchemeGuid.ToLowerInvariant()),
                ("'{0}'" -f $backupPath.Replace("'", "''")),
                ("'{0}'" -f $activeSchemeGuid.ToLowerInvariant()))
        )

        Register-HunterRollbackEntry -Key $key -Category 'Power' -Description "Active power scheme $activeSchemeGuid" -RestoreLines $restoreLines
    } catch {
        Write-Log "Failed to capture power-scheme rollback backup: $($_.Exception.Message)" 'WARN'
    }
}

function Save-HunterRunConfiguration {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [string[]]$SkipTaskIds = @(),
        [string]$CustomAppsListPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($script:RunConfigurationPath)) {
        return
    }

    Initialize-HunterDirectory (Split-Path -Parent $script:RunConfigurationPath)
    $payload = [ordered]@{
        GeneratedAt         = (Get-Date).ToString('o')
        ReleaseChannel      = [string]$script:HunterReleaseChannel
        ReleaseVersion      = [string]$script:HunterReleaseVersion
        BootstrapRevision   = [string]$script:HunterBootstrapRevision
        Mode                = [string]$Mode
        StrictMode          = [bool]$script:StrictMode
        AutomationSafe      = [bool]$script:IsAutomationRun
        DisableIPv6         = [bool]$script:DisableIPv6Requested
        DisableTeredo       = [bool]$script:DisableTeredoRequested
        DisableHags         = [bool]$script:DisableHagsRequested
        SkipTaskIds         = @($SkipTaskIds | Select-Object -Unique)
        CustomAppsListPath  = [string]$CustomAppsListPath
        ComputerName        = [string]$env:COMPUTERNAME
        UserName            = [string]$env:USERNAME
    }

    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $script:RunConfigurationPath -Encoding UTF8 -Force
}
