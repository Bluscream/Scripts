[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('CurrentUser', 'Machine')]
    [string]$Scope = 'CurrentUser',

    [Parameter(Mandatory=$false)]
    [switch]$Backup,

    [Parameter(Mandatory=$false)]
    [string]$backupJsonPath = 'D:\Scripts\drives\network-drives.json',

    [Parameter(Mandatory=$false)]
    [string]$backupScriptPath = 'D:\Scripts\drives\Restore-NetworkDrives.ps1',

    [Parameter(Mandatory=$false)]
    [switch]$Restore,

    [Parameter(Mandatory=$false)]
    [switch]$Clear,

    [Parameter(Mandatory=$false)]
    [switch]$NoPersist
)

function To-ProperCase {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$InputString
    )
    process {
        if ($null -eq $InputString) { return $null }
        return (($InputString -split ' ') | ForEach-Object {
            if ($_.Length -gt 0) {
                $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
            } else {
                $_
            }
        }) -join ' '
    }
}

function Get-MappedDrives {
    param(
        [string]$Scope
    )
    if ($Scope -eq 'Machine') {
        Write-Warning 'Machine scope for mapped drives is not fully supported. Defaulting to CurrentUser.'
        $Scope = 'CurrentUser'
    }
    if ($Scope -eq 'CurrentUser') {
        return Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like '\\*' }
    }
}

function Remove-AllMappedDrives {
    $currentDrives = Get-MappedDrives -Scope $Scope
    foreach ($drive in $currentDrives) {
        $letter = $drive.Name
        Try {
            Remove-PSDrive -Name $drive.Name -Force -ErrorAction Stop
            net use "$($drive.Name):" /delete /y | Out-Null
            Write-Host "Removed mapped drive $($drive.Name)."
        } Catch {
            Write-Warning "Failed to remove mapped drive $($drive.Name). $_"
        }
    }
}

Write-Verbose '--- Get-PSDrive ---'
Get-MappedDrives -Scope $Scope | Format-Table | Out-String | Write-Verbose

Write-Verbose '--- Get-WmiObject -Class Win32_MappedLogicalDisk ---'
Get-WmiObject -Class Win32_MappedLogicalDisk | Format-Table | Out-String | Write-Verbose

Write-Verbose '--- Get-CimInstance -ClassName Win32_MappedLogicalDisk ---'
Get-CimInstance -ClassName Win32_MappedLogicalDisk | Format-Table | Out-String | Write-Verbose

if ($Clear -and -not ($Backup -or $Restore)) {
    Remove-AllMappedDrives
    Write-Host 'All mapped drives cleared.'
    exit 0
}

function Get-NetworkDriveDescription {
    param(
        [string]$DriveLetter,
        [string]$UNCPath
    )
    $desc = $null
    $regPath = "HKCU:\\Network\\$DriveLetter"
    if (Test-Path $regPath) {
        try {
            $desc = (Get-ItemProperty -Path $regPath -Name Description -ErrorAction SilentlyContinue).Description
        } catch {}
    }
    if (-not $desc) {
        try {
            $wmi = Get-WmiObject -Class Win32_MappedLogicalDisk | Where-Object { $_.DeviceID -eq ("${DriveLetter}:") }
            if ($wmi -and $wmi.Description) {
                $desc = $wmi.Description
            }
        } catch {}
    }
    if (-not $desc) {
        try {
            $mapped = Get-CimInstance -ClassName Win32_MappedLogicalDisk | Where-Object { $_.DeviceID -eq ("${DriveLetter}:") }
            if ($mapped -and $mapped.VolumeName) {
                $desc = $mapped.VolumeName | To-ProperCase
            }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($desc)) {
        if ($UNCPath -match "^\\\\([^\\]+)\\([^\\]+)") {
            $desc = "$($matches[2]) ($($matches[1]))" | To-ProperCase
        } else {
            $desc = ''
        }
    }
    return $desc
}

function Generate-BackupScript {
    param(
        [array]$DriveData
    )
    $BackupScriptContent = @()
    $BackupScriptContent += '# This script restores mapped network drives.'
    $BackupScriptContent += 'param('
    $BackupScriptContent += '    [switch]$ForcePrompt'
    $BackupScriptContent += ')'
    $BackupScriptContent += ''
    $BackupScriptContent += 'function Restore-Drive {'
    $BackupScriptContent += '    param('
    $BackupScriptContent += '        [string]$DriveLetter,'
    $BackupScriptContent += '        [string]$UNCPath,'
    $BackupScriptContent += '        [string]$Description,'
    $BackupScriptContent += '        [bool]$ReconnectAtSignIn'
    $BackupScriptContent += '    )'
    $BackupScriptContent += '    Try {'
    $BackupScriptContent += '        # Try with saved credentials'
    $BackupScriptContent += '        $persistParam = if ($ReconnectAtSignIn) { "-Persist" } else { "" }'
    $BackupScriptContent += '        $cmd = "New-PSDrive -Name `$DriveLetter -PSProvider FileSystem -Root `$UNCPath -Scope Global $persistParam -Description `$Description -ErrorAction Stop"'
    $BackupScriptContent += '        Invoke-Expression $cmd'
    $BackupScriptContent += '        Write-Host "Restored $DriveLetter to $UNCPath using saved credentials."'
    $BackupScriptContent += '    } Catch {'
    $BackupScriptContent += '        Write-Warning "Failed to restore $DriveLetter to $UNCPath with saved credentials. Prompting for credentials..."'
    $BackupScriptContent += '        $cred = Get-Credential -Message "Enter credentials for $UNCPath"'
    $BackupScriptContent += '        Try {'
    $BackupScriptContent += '            $persistParam = if ($ReconnectAtSignIn) { "-Persist" } else { "" }'
    $BackupScriptContent += '            $cmd = "New-PSDrive -Name `$DriveLetter -PSProvider FileSystem -Root `$UNCPath -Scope Global $persistParam -Credential `$cred -Description `$Description -ErrorAction Stop"'
    $BackupScriptContent += '            Invoke-Expression $cmd'
    $BackupScriptContent += '            Write-Host "Restored $DriveLetter to $UNCPath with prompted credentials."'
    $BackupScriptContent += '        } Catch {'
    $BackupScriptContent += '            Write-Error "Failed to restore $DriveLetter to $UNCPath."'
    $BackupScriptContent += '        }'
    $BackupScriptContent += '    }'
    $BackupScriptContent += '}'
    $BackupScriptContent += ''
    foreach ($drive in $DriveData) {
        $letter = $drive.DriveLetter
        $unc = $drive.UNCPath
        $desc = $drive.Description
        $reconnect = $drive.ReconnectAtSignIn
        $BackupScriptContent += "Restore-Drive -DriveLetter '$letter' -UNCPath '$unc' -Description '$desc' -Persist `$reconnect"
    }
    $BackupScriptContent += ''
    $BackupScriptContent += 'Write-Host "All drives processed."'
    return $BackupScriptContent
}

if ($Backup) {
    $drives = Get-MappedDrives -Scope $Scope
    if (!$drives) {
        Write-Host 'No mapped network drives found.'
        exit 0
    }
    $driveData = @()
    foreach ($drive in $drives) {
        $letter = $drive.Name
        $unc = $drive.DisplayRoot.TrimEnd([char]0)
        $desc = Get-NetworkDriveDescription -DriveLetter $letter -UNCPath $unc
        $driveData += [PSCustomObject]@{
            DriveLetter = $letter
            UNCPath = $unc
            Description = $desc
            ReconnectAtSignIn = -not [bool]$NoPersist
        }
    }
    $driveData | ConvertTo-Json | Set-Content -Encoding UTF8 $backupJsonPath
    Write-Host "Backup JSON saved to $backupJsonPath."
    if (!(Test-Path $backupJsonPath)) {
        Write-Error "Backup JSON file $backupJsonPath not found."
        exit 1
    }
    $driveData = Get-Content $backupJsonPath | ConvertFrom-Json
    $BackupScriptContent = Generate-BackupScript -DriveData $driveData
    $BackupScriptContent | Set-Content -Encoding UTF8 $backupScriptPath
    Write-Host "Restore script saved to $backupScriptPath."
    if ($Clear) { Remove-AllMappedDrives; Write-Host 'All mapped drives cleared after backup.' }
}

if ($Restore) {
    if (!(Test-Path $backupJsonPath)) {
        Write-Error "Backup JSON file $backupJsonPath not found."
        exit 1
    }
    if ($Clear) { Remove-AllMappedDrives; Write-Host 'All mapped drives cleared before restore.' }
    $driveData = Get-Content $backupJsonPath | ConvertFrom-Json
    $driveData | Select-Object DriveLetter, UNCPath, Description, ReconnectAtSignIn | Format-Table -AutoSize | Out-String | Write-Host
    function Restore-Drive {
        param(
            [string]$DriveLetter,
            [string]$UNCPath,
            [string]$Description,
            [bool]$ReconnectAtSignIn
        )
        $NoPersist = -not $ReconnectAtSignIn
        Try {
            if (-not $NoPersist) {
                New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Persist -Description $Description -ErrorAction Stop
            } else {
                New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Description $Description -ErrorAction Stop
            }
            Write-Host "Restored $DriveLetter to $UNCPath using saved credentials."
        } Catch {
            Write-Error "Error details: $($_.Exception.Message)"
            if ($_.Exception.Message -match "The local device name is already in use") {
                return
            }
            Write-Warning "Failed to restore $DriveLetter to $UNCPath with saved credentials. Prompting for credentials..."
            $cred = Get-Credential -Message "Enter credentials for $UNCPath"
            Try {
                if (-not $NoPersist) {
                    New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Persist -Credential $cred -Description $Description -ErrorAction Stop
                } else {
                    New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Credential $cred -Description $Description -ErrorAction Stop
                }
                Write-Host "Restored $DriveLetter to $UNCPath with prompted credentials."
            } Catch {
                Write-Error "Error details $($_.Exception.Message)"
                Write-Error "Failed to restore $DriveLetter to $UNCPath."
            }
        }
    }
    foreach ($drive in $driveData) {
        Restore-Drive -DriveLetter $drive.DriveLetter -UNCPath $drive.UNCPath -Description $drive.Description -ReconnectAtSignIn ([bool]$drive.ReconnectAtSignIn)
    }
    Write-Host "All drives processed."
    exit 0
}