param (
    [switch]$pip,
    [switch]$npm,
    [switch]$windows,
    [switch]$eventlogs,
    [switch]$all,
    [switch]$default,
    [switch]$skipUAC = $false,
    [switch]$mappedDrives,
    [string[]]$WhiteListedUsers = @("Bluscream"),
    [switch]$help
)

$allByDefault = $false # Can set to true to update everything by default instead of showing help

function Elevate-Script {
    if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
            $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
            Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine
            Exit
        }
    }
}
function Set-Title {
    param (
        [string]$message,
        [string]$color = 'Green'
    )
    $Host.UI.RawUI.WindowTitle = $message
    Write-Host $message -ForegroundColor $color
}
Function pause ($message) {
    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$message")
    }
    else {
        Write-Host "$message" -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

function Backup-Pip {
    Set-Title "Backing up pip packages"
    # Get a list of all installed pip packages with their versions
    $pipList = pip list --format=freeze

    # Specify the backup file path
    $backupFilePath = "requirements.txt"

    # Create the backup file
    $pipList | Out-File -FilePath $backupFilePath -Encoding utf8

    Write-Host "Pip packages have been backed up to $backupFilePath"
}
function Clear-Pip {
    # List of essential pip packages that should not be uninstalled
    $essentialPackages = "wheel", "setuptools", "pip"

    Set-Title "Cleaning pip packages except ($essentialPackages)"

    # Get a list of all installed pip packages
    $allPackages = pip list --format=freeze | ForEach-Object { $_.Split('==')[0] }

    # Filter out the essential packages
    $unimportantPackages = $allPackages | Where-Object { $_ -notin $essentialPackages }

    # Uninstall the unimportant packages
    foreach ($package in $unimportantPackages) {
        pip uninstall -y $package
    }
}

function Backup-Npm {
    Set-Title "Backing up npm packages"
    # Check if the npm directory exists
    $npmDir = "$env:APPDATA\npm"
    if (-not (Test-Path $npmDir)) {
        Write-Error "Npm directory not found: $npmDir"
        return
    }
    
    # Get a list of all installed npm packages with their versions
    $npmList = npm list --global --json | ConvertFrom-Json
    
    # Check if the npmList object has a dependencies property
    if ($null -eq $npmList.dependencies) {
        Write-Error "No dependencies found in npm list output"
        return
    }
    
    # Convert the package list to JSON format
    $npmListJson = $npmList.dependencies | ConvertTo-Json
    
    # Specify the backup file path
    $backupFilePath = "packages.json"
    
    # Create the backup file
    $npmListJson | Out-File -FilePath $backupFilePath -Encoding utf8
    
    Write-Host "Npm packages have been backed up to $backupFilePath"
}
function Clear-Npm {
    # List of essential npm packages that should not be uninstalled
    $essentialPackages = "npm"

    Set-Title "Cleaning npm packages except ($essentialPackages)"

    # Get a list of all installed npm packages
    $allPackages = npm list --depth=0 --global --json | ConvertFrom-Json | ForEach-Object { $_.dependencies | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name } }

    # Filter out the essential packages
    $unimportantPackages = $allPackages | Where-Object { $_ -notin $essentialPackages }

    # Uninstall the unimportant packages
    foreach ($package in $unimportantPackages) {
        npm uninstall -g $package
    }
}

function Remove-MappedDrives {
    Set-Title "Removing mapped network drives"
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like '\\*' }
    foreach ($drive in $drives) {
        $letter = $drive.Name
        try {
            Remove-PSDrive -Name $letter -Force -ErrorAction Stop
            net use "$($letter):" /delete /y | Out-Null
            Write-Host "Removed mapped drive $letter."
        } catch {
            Write-Warning "Failed to remove mapped drive $letter. $_"
        }
    }
}

function Clear-Windows {
    Set-Title "Cleaning Windows"

    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*' | % {
        New-ItemProperty -Path $_.PSPath -Name StateFlags0001 -Value 2 -PropertyType DWord -Force
    };
    Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' # -WindowStyle Hidden
    # Get-Process -Name cleanmgr,dismhost -ErrorAction SilentlyContinue | Wait-Process

    $users = Get-ChildItem -Path $env:SystemDrive\Users -Directory
    foreach ($user in $users) {
        $tempDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Temp'
        Set-Title "Cleaning %temp% ($tempDir)"
        Remove-Item -Path $tempDir\* -Recurse -Force
        # Clear CrashDumps folder for all users
        $crashDumpsDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\CrashDumps'
        if (Test-Path $crashDumpsDir) {
            Set-Title "Cleaning CrashDumps ($crashDumpsDir)"
            Remove-Item -Path "$crashDumpsDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Clear NVIDIA cache folders for all users
        $nvidiaCacheFolders = @("DXCache", "GLCache", "OptixCache")
        foreach ($cacheFolder in $nvidiaCacheFolders) {
            $nvidiaPath = Join-Path -Path $user.FullName -ChildPath "AppData\Local\NVIDIA\$cacheFolder"
            if (Test-Path $nvidiaPath) {
                Set-Title "Cleaning NVIDIA $cacheFolder ($nvidiaPath)"
                Remove-Item -Path "$nvidiaPath\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        # Clear INetCache and WebCache folders for all users
        $inetCacheDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Microsoft\Windows\INetCache'
        if (Test-Path $inetCacheDir) {
            Set-Title "Cleaning INetCache ($inetCacheDir)"
            Remove-Item -Path "$inetCacheDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        $webCacheDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Microsoft\Windows\WebCache'
        if (Test-Path $webCacheDir) {
            Set-Title "Cleaning WebCache ($webCacheDir)"
            Remove-Item -Path "$webCacheDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($WhiteListedUsers -notcontains $user.Name) {
            $downloadsDir = Join-Path -Path $user.FullName -ChildPath 'Downloads'
            if (Test-Path $downloadsDir) {
                Set-Title "Cleaning Downloads ($downloadsDir)"
                Remove-Item -Path "$downloadsDir\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Set-Title "Cleaning Windows ($env:windir\Temp)"
    Remove-Item -Path $env:windir\Temp\* -Recurse -Force

    Set-Title "Cleaning Windows prefetch"
    Remove-Item -Path $env:windir\Prefetch\* -Recurse -Force

    Set-Title "Cleaning Windows memory dump"
    Remove-Item -Path $env:windir\memory.dmp -Force

    Set-Title "Cleaning Windows Update cache"
    net stop wuauserv
    Remove-Item -Path $env:windir\SoftwareDistribution\* -Recurse -Force
    net start wuauserv
}
function Clear-WindowsEventlogs {
    Set-Title "Cleaning Windows event logs"
    $LogNames = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LogName
    Write-Host "Found $($LogNames.Count) event logs"

    foreach ($LogName in $LogNames) {
        $txt = "Clearing $LogName"
        $logSizeMB = -1
        try {
            $fistLogEvent = Get-WinEvent -LogName $LogName -MaxEvents 1 --ErrorAction SilentlyContinue
            $logSizeMB = $fistLogEvent.MaximumSizeInBytes / 1MB
            $txt += " ($logSizeMB MB)"
        } catch { }
        Write-Host $txt
        try {
            wevtutil.exe cl "$LogName"
        } catch {
            Write-Host "Failed to clear $LogName. Error: $_"
        }
    }
}

if ($allByDefault -and $MyInvocation.BoundParameters.Count -eq 0) {
    $pip = $true
    $npm = $true
    $windows = $true
    $eventlogs = $true
}

if (-Not $skipUAC) { Elevate-Script }
if ($all -or $mappedDrives) {
    Remove-MappedDrives
}
if ($all -or $default -or $npm) {
    Backup-Npm
    Clear-Npm
}
if ($all -or $default -or $pip) {
    Backup-Pip
    Clear-Pip
}
if ($all -or $default -or $windows) {
    Clear-Windows
}
if ($all -or $default -or $eventlogs) {
    Clear-WindowsEventlogs
}

if ($PauseBeforeExit) {
    pause "Press any key to exit"
}