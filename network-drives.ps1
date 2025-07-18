param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('CurrentUser', 'Machine')]
    [string]$Scope = 'CurrentUser',

    [Parameter(Mandatory=$false)]
    [switch]$Backup,

    [Parameter(Mandatory=$false)]
    [switch]$Restore,

    [Parameter(Mandatory=$false)]
    [switch]$RestoreScript,

    [Parameter(Mandatory=$false)]
    [switch]$DeleteOnBackup
)

$backupJson = 'network-drives-backup.json'
$backupScript = 'Restore-NetworkDrives.ps1'

function Get-MappedDrives {
    param(
        [string]$Scope
    )
    if ($Scope -eq 'Machine') {
        Write-Warning 'Machine scope for mapped drives is not fully supported. Defaulting to CurrentUser.'
        $Scope = 'CurrentUser'
    }
    if ($Scope -eq 'CurrentUser') {
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like '\\*' }
        return $drives
    }
}

function Get-NetworkDriveDescription {
    param(
        [string]$DriveLetter
    )
    $desc = $null
    $regPath = "HKCU:\\Network\\$DriveLetter"
    if (Test-Path $regPath) {
        try {
            $desc = (Get-ItemProperty -Path $regPath -Name Description -ErrorAction SilentlyContinue).Description
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($desc)) {
        $desc = ''
    }
    return $desc
}

function Generate-RestoreScript {
    param(
        [array]$DriveData
    )
    $restoreScriptContent = @()
    $restoreScriptContent += '# This script restores mapped network drives.'
    $restoreScriptContent += 'param('
    $restoreScriptContent += '    [switch]$ForcePrompt'
    $restoreScriptContent += ')'
    $restoreScriptContent += ''
    $restoreScriptContent += 'function Restore-Drive {'
    $restoreScriptContent += '    param('
    $restoreScriptContent += '        [string]$DriveLetter,'
    $restoreScriptContent += '        [string]$UNCPath,'
    $restoreScriptContent += '        [string]$Description'
    $restoreScriptContent += '    )'
    $restoreScriptContent += '    Try {'
    $restoreScriptContent += '        # Try with saved credentials'
    $restoreScriptContent += '        New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Persist -Description $Description -ErrorAction Stop'
    $restoreScriptContent += '        Write-Host "Restored $DriveLetter to $UNCPath using saved credentials."'
    $restoreScriptContent += '    } Catch {'
    $restoreScriptContent += '        Write-Warning "Failed to restore $DriveLetter to $UNCPath with saved credentials. Prompting for credentials..."'
    $restoreScriptContent += '        $cred = Get-Credential -Message "Enter credentials for $UNCPath"'
    $restoreScriptContent += '        Try {'
    $restoreScriptContent += '            New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Persist -Credential $cred -Description $Description -ErrorAction Stop'
    $restoreScriptContent += '            Write-Host "Restored $DriveLetter to $UNCPath with prompted credentials."'
    $restoreScriptContent += '        } Catch {'
    $restoreScriptContent += '            Write-Error "Failed to restore $DriveLetter to $UNCPath."'
    $restoreScriptContent += '        }'
    $restoreScriptContent += '    }'
    $restoreScriptContent += '}'
    $restoreScriptContent += ''
    foreach ($drive in $DriveData) {
        $letter = $drive.DriveLetter
        $unc = $drive.UNCPath
        $desc = $drive.Description
        $restoreScriptContent += "Restore-Drive -DriveLetter '$letter' -UNCPath '$unc' -Description '$desc'"
    }
    $restoreScriptContent += ''
    $restoreScriptContent += 'Write-Host "All drives processed."'
    return $restoreScriptContent
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
        $desc = Get-NetworkDriveDescription -DriveLetter $letter
        $driveData += [PSCustomObject]@{
            DriveLetter = $letter
            UNCPath = $unc
            Description = $desc
        }
    }
    $driveData | ConvertTo-Json | Set-Content -Encoding UTF8 $backupJson
    Write-Host "Backup JSON saved to $backupJson."
    $restoreScriptContent = Generate-RestoreScript -DriveData $driveData
    $restoreScriptContent | Set-Content -Encoding UTF8 $backupScript
    Write-Host "Restore script saved to $backupScript."
    if ($DeleteOnBackup) {
        # Unmount and delete all mapped network drives
        foreach ($drive in $drives) {
            $letter = $drive.Name
            Try {
                Remove-PSDrive -Name $letter -Force -ErrorAction Stop
                Write-Host "Removed mapped drive $letter."
            } Catch {
                Write-Warning "Failed to remove mapped drive $letter. $_"
            }
        }
    }
    exit 0
}

if ($Restore) {
    if (!(Test-Path $backupJson)) {
        Write-Error "Backup JSON file $backupJson not found."
        exit 1
    }
    $driveData = Get-Content $backupJson | ConvertFrom-Json
    function Restore-Drive {
        param(
            [string]$DriveLetter,
            [string]$UNCPath,
            [string]$Description
        )
        Try {
            New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Persist -Description $Description -ErrorAction Stop
            Write-Host "Restored $DriveLetter to $UNCPath using saved credentials."
        } Catch {
            Write-Warning "Failed to restore $DriveLetter to $UNCPath with saved credentials. Prompting for credentials..."
            $cred = Get-Credential -Message "Enter credentials for $UNCPath"
            Try {
                New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $UNCPath -Scope Global -Persist -Credential $cred -Description $Description -ErrorAction Stop
                Write-Host "Restored $DriveLetter to $UNCPath with prompted credentials."
            } Catch {
                Write-Error "Failed to restore $DriveLetter to $UNCPath."
            }
        }
    }
    foreach ($drive in $driveData) {
        Restore-Drive -DriveLetter $drive.DriveLetter -UNCPath $drive.UNCPath -Description $drive.Description
    }
    Write-Host "All drives processed."
    exit 0
}

if ($RestoreScript) {
    if (!(Test-Path $backupJson)) {
        Write-Error "Backup JSON file $backupJson not found."
        exit 1
    }
    $driveData = Get-Content $backupJson | ConvertFrom-Json
    $restoreScriptContent = Generate-RestoreScript -DriveData $driveData
    $restoreScriptContent | Set-Content -Encoding UTF8 $backupScript
    Write-Host "Restore script saved to $backupScript."
    exit 0
}

Write-Host 'No action specified. Use -Backup, -Restore, or -RestoreScript.' 