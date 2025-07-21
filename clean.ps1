param (
    [Parameter(Position=0, Mandatory=$false)]
    # [ValidateSet(...)] removed for manual validation
    [string[]]$Actions = @(),
    [switch]$SkipUAC = $false,
    [string[]]$WhitelistedUsers = @("Bluscream"),
    [string]$Message = "Message"
)

# Import Bluscream helper functions (must come first)
. "$PSScriptRoot/powershell/bluscream.ps1"
# Import the shared steps logic (depends on bluscream.ps1)
. "$PSScriptRoot/powershell/steps.ps1"

# --- Cleaning function definitions ---
function Backup-Pip {
    Set-Title "Backing up pip packages"
    $pipList = pip list --format=freeze
    $backupFilePath = "requirements.txt"
    $pipList | Out-File -FilePath $backupFilePath -Encoding utf8
    Write-Host "Pip packages have been backed up to $backupFilePath"
}
function Clear-Pip {
    $packageWhitelist = "wheel", "setuptools", "pip"
    Set-Title "Cleaning pip packages except ($packageWhitelist)"
    $allPackages = pip list --format=freeze | ForEach-Object { $_.Split('==')[0] }
    $unimportantPackages = $allPackages | Where-Object { $_ -notin $packageWhitelist }
    foreach ($package in $unimportantPackages) {
        pip uninstall -y $package
    }
}
function Backup-Npm {
    Set-Title "Backing up npm packages"
    $npmDir = "$env:APPDATA\npm"
    if (-not (Test-Path $npmDir)) {
        Write-Host "Npm directory not found: $npmDir" -ForegroundColor DarkGray
        return
    }
    $npmList = npm list --global --json | ConvertFrom-Json
    if ($null -eq $npmList.dependencies) {
        Write-Host "No dependencies found in npm list output: $npmList" -ForegroundColor DarkGray
        return
    }
    $npmListJson = $npmList.dependencies | ConvertTo-Json
    $backupFilePath = "packages.json"
    $npmListJson | Out-File -FilePath $backupFilePath -Encoding utf8
    Write-Host "Npm packages have been backed up to $backupFilePath"
}
function Clear-Npm {
    $packageWhitelist = "npm"
    Set-Title "Cleaning npm packages except ($packageWhitelist)"
    $npmList = npm list --depth=0 --global --json | ConvertFrom-Json
    if ($null -eq $npmList.dependencies) {
        Write-Host "No global npm packages found." -ForegroundColor DarkGray
        return
    }
    $allPackages = $npmList.dependencies.psobject.Properties.Name
    $unimportantPackages = $allPackages | Where-Object { $_ -notin $packageWhitelist }
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
function Clear-Downloads {
    Set-Title "Cleaning Downloads folders"
    Add-Type -AssemblyName Microsoft.VisualBasic
    $users = Get-ChildItem -Path $env:SystemDrive\Users -Directory
    foreach ($user in $users) {
        if ($WhitelistedUsers -notcontains $user.Name) {
            $downloadsDir = Join-Path -Path $user.FullName -ChildPath 'Downloads'
            if (Test-Path $downloadsDir) {
                $items = Get-ChildItem -Path $downloadsDir -Force
                foreach ($item in $items) {
                    try {
                        if ($item.PSIsContainer) {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        } else {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        }
                        Write-Host "Moved to Recycle Bin: $($item.FullName)"
                    } catch {
                        Write-Host "Failed to move to Recycle Bin: $($item.FullName) - $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
            }
        }
    }
}
function Clear-Windows {
    Set-Title "Cleaning Windows"
    Write-Host "Stopping Windows Update Service"
    net stop wuauserv
    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*' | % {
        New-ItemProperty -Path $_.PSPath -Name StateFlags0001 -Value 2 -PropertyType DWord -Force
    }
    Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' -WindowStyle Minimized
    $users = Get-ChildItem -Path $env:SystemDrive\Users -Directory
    foreach ($user in $users) {
        $tempDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Temp'
        Clear-Directory -Path $tempDir
        $crashDumpsDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\CrashDumps'
        Clear-Directory -Path $crashDumpsDir
        $inetCacheDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Microsoft\Windows\INetCache'
        Clear-Directory -Path $inetCacheDir
        $webCacheDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Microsoft\Windows\WebCache'
        Clear-Directory -Path $webCacheDir
        $nvidiaCacheFolders = @("DXCache", "GLCache", "OptixCache")
        foreach ($cacheFolder in $nvidiaCacheFolders) {
            $nvidiaPath = Join-Path -Path $user.FullName -ChildPath "AppData\Local\NVIDIA\$cacheFolder"
            Clear-Directory -Path $nvidiaPath
        }
    }
    Clear-Directory -Path "$env:windir\Temp"
    Clear-Directory -Path "$env:windir\Prefetch"
    if (Test-Path "$env:windir\memory.dmp") {
        Remove-Item -Path "$env:windir\memory.dmp" -Force
    }
    Clear-Directory -Path "$env:windir\SoftwareDistribution"
    Write-Host "Starting Windows Update Service"
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

# Extend or override $possibleSteps directly
$possibleSteps["clean"] = @{
        "pip" = @{
            Description = "Clean pip cache and packages"
            Code = { Backup-Pip; Clear-Pip }
        }
        "npm" = @{
            Description = "Clean npm cache and node_modules"
            Code = { Backup-Npm; Clear-Npm }
        }
        "windows" = @{
            Description = "Clean Windows temp files, caches, and system folders"
            Code = { Clear-Windows }
        }
        "eventlogs" = @{
            Description = "Clear Windows event logs"
            Code = { Clear-WindowsEventlogs }
        }
        "netdrives" = @{
            Description = "Remove mapped network drives"
            Code = { Remove-MappedDrives }
        }
        "downloads" = @{
            Description = "Clean Downloads folders for all users except whitelisted ones"
            Code = { Clear-Downloads }
        }
    }
$possibleSteps["meta"] = @{
        "all" = @{
            Description = "Run all cleaning actions"
        Actions = $possibleSteps["clean"].Keys
        }
        "default" = @{
        Description = "Default actions"
            Actions = @("elevate", "pip", "npm", "windows", "eventlogs", "pause")
    }
}

# To remove a special step, set it to null or use Remove:
# $possibleSteps["special"].Remove("shutdown")

# Expand actions (handle meta-actions)
$actionsToRun = Expand-Steps -Steps $possibleSteps -Actions $Actions

Write-Host "The following actions will be run:" -ForegroundColor Cyan

# Run the steps
Run-Steps -Steps $possibleSteps -ActionsToRun $actionsToRun

if ($PauseBeforeExit) {
    Pause "Press any key to exit"
}