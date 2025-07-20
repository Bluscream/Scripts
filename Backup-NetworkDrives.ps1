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
    [switch]$NoPersist,

    [Parameter(Mandatory=$false)]
    [switch]$Test,

    [Parameter(Mandatory=$false)]
    [switch]$SkipUAC
)

# region FUNCTIONS
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
function Is-RunAsAdmin {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    $is6k = [int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator -and $is6k)
}
function Elevate-Self {
    $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
    Start-Process -FilePath pwsh.exe -Verb Runas -ArgumentList $CommandLine
    exit
}
function New-DriveDataObject {
    param(
        [string]$DriveLetter,
        [string]$UNCPath,
        [string]$Description = '',
        [bool]$ReconnectAtSignIn = -not $NoPersist
    )
    return [PSCustomObject]@{
        DriveLetter = $DriveLetter
        UNCPath = $UNCPath
        Description = $Description
        ReconnectAtSignIn = $ReconnectAtSignIn
    }
}
function Get-AllAvailableDrives {
    # Returns all available UNC paths on the current networks as seen in Windows Explorer's "Network" location.
    # Output: Array of New-DriveDataObject objects

    $driveData = @()

    # Get all computers visible in the network neighborhood
    try {
        $networkComputers = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
        if (-not $networkComputers) {
            $networkComputers = @()
        }
    } catch {
        $networkComputers = @()
    }

    # Use Net View to enumerate network computers if WMI fails or returns nothing
    if ($networkComputers.Count -eq 0) {
        try {
            $netView = net view | Select-String '\\\\'
            foreach ($line in $netView) {
                $name = ($line -replace '^\s*\\\\', '').Split(' ')[0]
                if ($name) {
                    $networkComputers += $name
                }
            }
        } catch {}
    }

    foreach ($computer in $networkComputers | Sort-Object -Unique) {
        # Get shared folders for each computer
        try {
            $shares = net view "\\$computer" 2>$null | Select-String 'Disk' | ForEach-Object {
                ($_ -replace '^\s+', '').Split(' ')[0]
            }
            foreach ($share in $shares) {
                if ($share -and $share -ne 'IPC$') {
                    $driveData += New-DriveDataObject -DriveLetter '' -UNCPath "\\$computer\$share" -Description "$share ($computer)"
                }
            }
        } catch {}
    }

    return $driveData
}
function Get-MappedDrives {
    param(
        [string]$Scope
    )
    if ($Scope -eq 'Machine') {
        Write-Warning 'Machine scope for mapped drives is not fully supported. Defaulting to CurrentUser.'
        $Scope = 'CurrentUser'
    }
    $driveData = @()
    if ($Scope -eq 'CurrentUser') {
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like '\\*' }
        foreach ($drive in $drives) {
            $letter = $drive.Name
            $unc = $drive.DisplayRoot.TrimEnd([char]0)
            $desc = Get-MappedDriveDescription -DriveLetter $letter -UNCPath $unc
            $reconnect = $true
            $driveData += New-DriveDataObject -DriveLetter $letter -UNCPath $unc -Description $desc -ReconnectAtSignIn $reconnect
        }
    }
    return $driveData
}
function Remove-AllMappedDrives {
    $currentDrives = Get-MappedDrives -Scope $Scope
    foreach ($drive in $currentDrives) {
        $letter = $drive.DriveLetter
        Try {
            Remove-PSDrive -Name $letter -Force -ErrorAction Stop
            net use "$($letter):" /delete /y | Out-Null
            Write-Host "Removed mapped drive $letter."
        } Catch {
            Write-Warning "Failed to remove mapped drive $letter. $_"
        }
    }
}
function Get-MappedDriveDescription {
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
function Get-NetworkDriveCredentials {
    param(
        [string]$Hostname
    )
    $storedCred = $null
    try {
        if (-not (Get-Module -ListAvailable -Name TUN.CredentialManager)) {
            Install-Module -Name TUN.CredentialManager -Force -Scope CurrentUser
        }
        $storedCred = Get-StoredCredential -Target $Hostname
    } catch {
        $storedCred = $null
    }
    if (-not $storedCred) {
        $storedCred = Get-Credential -Message "Enter credentials for $Hostname"
        # Store for future use
        New-StoredCredential -Target $Hostname -Username $storedCred.UserName -Pass $storedCred.GetNetworkCredential().Password
        return $storedCred
    }
    # Convert to PSCredential if needed
    if ($storedCred -is [PSCredential]) {
        return $storedCred
    } elseif ($storedCred.UserName -and $storedCred.Password) {
        $securePass = $storedCred.Password
        if ($securePass -isnot [System.Security.SecureString]) {
            $securePass = ConvertTo-SecureString $storedCred.Password -AsPlainText -Force
        }
        return New-Object System.Management.Automation.PSCredential ($storedCred.UserName, $securePass)
    }
    return $null
}
function Restore-Drive {
    param(
        [string]$DriveLetter,
        [string]$UNCPath,
        [string]$Description,
        [bool]$ReconnectAtSignIn
    )
    $psDriveParams = @{
        Name        = $DriveLetter
        PSProvider  = 'FileSystem'
        Root        = $UNCPath
        Scope       = 'Global'
        Description = $Description
        ErrorAction = 'Stop'
    }
    if ($ReconnectAtSignIn) { $psDriveParams['Persist'] = $true }
    Try {
        New-PSDrive @psDriveParams
        Write-Host "Restored $DriveLetter to $UNCPath using saved credentials."
    } Catch {
        Write-Error "Error details: $($_.Exception.Message)"
        if ($_.Exception.Message -match "The local device name is already in use") {
            return
        }
        Write-Warning "Failed to restore $DriveLetter to $UNCPath with saved credentials. Prompting for credentials..."
        $hostname = ($UNCPath -replace '^\\\\([^\\]+)\\.*', '$1')
        $storedCred = Get-DriveCredentials -Hostname $hostname
        if ($storedCred) {
            $psDriveParams['Credential'] = $storedCred
            try {
                New-PSDrive @psDriveParams
                Write-Host "Restored $DriveLetter to $UNCPath using stored credentials for $hostname"
                return
            } catch {
                Write-Warning "Stored credentials for $hostname failed: $($_.Exception.Message)"
            }
            $psDriveParams.Remove('Credential')
        }
    }
}
function Generate-RestoreScript {
    param(
        [array]$DriveData
    )
    $BackupScriptContent = @()
    $BackupScriptContent += '# This script restores mapped network drives.'
    $BackupScriptContent += ''
    # Use reflection to get the source code of Is-RunAsAdmin and Elevate-Self and add to $BackupScriptContent
    $funcNames = @('Is-RunAsAdmin', 'Elevate-Self')
    foreach ($func in $funcNames) {
        $funcObj = Get-Command $func -CommandType Function
        if ($funcObj) {
            $funcSource = ($funcObj.ScriptBlock.ToString() -split "`r?`n")
            $BackupScriptContent += ''
            $BackupScriptContent += "function $func {"
            foreach ($line in $funcSource[1..($funcSource.Count-2)]) {
                $BackupScriptContent += $line
            }
            $BackupScriptContent += '}'
        }
    }
    $BackupScriptContent += ''
    $BackupScriptContent += 'if (-not (Is-RunAsAdmin)) {'
    $BackupScriptContent += '    Write-Host "Script is not running as administrator. Attempting to relaunch with elevation..."'
    $BackupScriptContent += '    Elevate-Self'
    $BackupScriptContent += '    exit'
    $BackupScriptContent += '}'
    $BackupScriptContent += ''
    foreach ($drive in $DriveData) {
        $persistFlag = if ($drive.ReconnectAtSignIn) { '-Persist' } else { '' }
        $BackupScriptContent += "New-PSDrive -Scope Global -PSProvider FileSystem -Name $($drive.DriveLetter) -Root '$($drive.UNCPath)' -Description '$($drive.Description)' $persistFlag"
    }
    $BackupScriptContent += ''
    $BackupScriptContent += 'Write-Host "All drives processed."'
    return $BackupScriptContent
}
function Test-PathAccess {
    param(
        [string]$Path
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $canRead = $false
    $canWrite = $false
    try {
        Get-ChildItem -Path $Path -ErrorAction Stop | Out-Null
        $canRead = $true
    } catch {
        Write-Error "[Test-PathAccess] Cannot read from $Path $($_.Exception.Message)"
    }
    try {
        $tempFile = Join-Path $Path ("test_" + [guid]::NewGuid().ToString() + ".tmp")
        Set-Content -Path $tempFile -Value 'test' -ErrorAction Stop
        Remove-Item -Path $tempFile -Force -ErrorAction Stop
        $canWrite = $true
    } catch {
        Write-Warning "[Test-PathAccess] Cannot write to $Path $($_.Exception.Message)"
    }
    $stopwatch.Stop()
    $elapsedMs = $stopwatch.ElapsedMilliseconds
    Write-Host "[Test-PathAccess] CanRead $canRead, CanWrite $canWrite, ElapsedMs $elapsedMs for $Path"
    return [PSCustomObject]@{
        canRead   = $canRead
        canWrite  = $canWrite
        elapsedMs = $elapsedMs
    }
}
function Test-NetworkDrive {
    param(
        [string]$DriveLetter,
        [string]$UNCPath
    )
    $mounted = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -eq $DriveLetter -and $_.DisplayRoot -eq $UNCPath }
    $pathToTest = $null
    $testResult = $null
    if ($mounted) {
        $pathToTest = "$($DriveLetter):\"
        # Local drive, no credential needed
        $testResult = Test-PathAccess -Path $pathToTest
    } else {
        $pathToTest = $UNCPath
        $hostName = (($UNCPath -replace '^\\\\([^\\]+)\\.*', '$1'))
        Write-Host "$UNCPath ($hostName)"
        $testResult = Test-PathAccess -Path $UNCPath
    }
    return ($testResult.canRead -and $testResult.canWrite)
}
# endregion FUNCTIONS
# region LOGIC
Write-Verbose '--- Get-PSDrive ---'
Get-MappedDrives -Scope $Scope | Format-Table | Out-String | Write-Verbose
Write-Verbose '--- Get-WmiObject -Class Win32_MappedLogicalDisk ---'
Get-WmiObject -Class Win32_MappedLogicalDisk | Format-Table | Out-String | Write-Verbose
Write-Verbose '--- Get-CimInstance -ClassName Win32_MappedLogicalDisk ---'
Get-CimInstance -ClassName Win32_MappedLogicalDisk | Format-Table | Out-String | Write-Verbose

if ($Test -and -not ($Backup -or $Restore)) {
    $driveData = Get-MappedDrives -Scope $Scope
    foreach ($drive in $driveData) {
        $result = Test-NetworkDrive -DriveLetter $drive.DriveLetter -UNCPath $drive.UNCPath
        Write-Host "Test-NetworkDrive for $($drive.DriveLetter) $($drive.UNCPath) => $result"
    }
}

if ($Backup) {
    $drives = Get-MappedDrives -Scope $Scope # returns list of New-DriveDataObject
    if (!$drives) {
        Write-Host 'No mapped network drives found.'
        exit 0
    }
    $drives | ConvertTo-Json | Set-Content -Encoding UTF8 $backupJsonPath
    Write-Host "Backup JSON saved to $backupJsonPath."
    if (!(Test-Path $backupJsonPath)) {
        Write-Error "Backup JSON file $backupJsonPath not found."
        exit 1
    }
    $BackupScriptContent = Generate-RestoreScript -DriveData $drives
    $BackupScriptContent | Set-Content -Encoding UTF8 $backupScriptPath
    Write-Host "Restore script saved to $backupScriptPath."
    if ($Clear) { Remove-AllMappedDrives; Write-Host 'All mapped drives cleared after backup.' }
}

if (-not $SkipUAC -and -not (Is-RunAsAdmin)) {
    Write-Host "Script is not running as administrator. Attempting to relaunch with elevation..."
    Elevate-Self
    exit
}

if ($Clear -and -not ($Backup -or $Restore)) {
    Remove-AllMappedDrives
    Write-Host 'All mapped drives cleared.'
}

if ($Restore) {
    if (!(Test-Path $backupJsonPath)) {
        Write-Error "Backup JSON file $backupJsonPath not found."
        exit 1
    }
    if ($Clear) { Remove-AllMappedDrives; Write-Host 'All mapped drives cleared before restore.' }
    $driveData = Get-Content $backupJsonPath | ConvertFrom-Json
    $driveData | Select-Object DriveLetter, UNCPath, Description, ReconnectAtSignIn | Format-Table -AutoSize | Out-String | Write-Host
    foreach ($drive in $driveData) {
        if ($Test) {
            $testResult = Test-NetworkDrive -DriveLetter $drive.DriveLetter -UNCPath $drive.UNCPath
            Write-Host "Test-NetworkDrive for $($drive.DriveLetter): $($drive.UNCPath) => $testResult"
            if ($testResult) {
                Restore-Drive -DriveLetter $drive.DriveLetter -UNCPath $drive.UNCPath -Description $drive.Description -ReconnectAtSignIn ([bool]$drive.ReconnectAtSignIn)
            }
        } else {
            Restore-Drive -DriveLetter $drive.DriveLetter -UNCPath $drive.UNCPath -Description $drive.Description -ReconnectAtSignIn ([bool]$drive.ReconnectAtSignIn)
        }
    }
    Write-Host "All drives processed."
    exit 0
}
# endregion LOGIC