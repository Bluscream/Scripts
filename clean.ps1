param (
    [Parameter(Position=0, Mandatory=$false)]
    # [ValidateSet(...)] removed for manual validation
    [string[]]$Actions = @(),
    [switch]$SkipUAC = $false,
    [string[]]$WhitelistedUsers = @("Bluscream"),
    [string]$Message = "Message",
    [switch]$Help
)

$possibleActions = @{
    "clean" = @{
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
    "meta" = @{
        "all" = @{
            Description = "Run all cleaning actions"
            Actions = @()  # placeholder, set below
        }
        "default" = @{
            Description = "Default cctions"
            Actions = @("elevate", "pip", "npm", "windows", "eventlogs", "pause")
        }
    }
    "special" = @{
        "toast" = @{
            Description = "Show a toast notification"
            Code = {
                try {
                    if (Get-Module -ListAvailable -Name BurntToast) {
                        Import-Module BurntToast -ErrorAction SilentlyContinue
                        New-BurntToastNotification -Text "Clean.ps1", $Message
                    } else {
                        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
                        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
                        $textNodes = $template.GetElementsByTagName("text")
                        $textNodes.Item(0).AppendChild($template.CreateTextNode("Clean.ps1")) | Out-Null
                        $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
                        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
                        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell")
                        $notifier.Show($toast)
                    }
                } catch {
                    Write-Host "[SPECIAL] Toast notification (no compatible method found)" -ForegroundColor Magenta
                }
            }
        }
        "shutdown" = @{
            Description = "Shutdown the computer"
            Code = {
                try {
                    Stop-Computer -Force
                } catch {
                    Write-Host "[SPECIAL] Failed to shutdown: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "logout" = @{
            Description = "Log out the current user"
            Code = {
                try {
                    shutdown.exe /l
                } catch {
                    Write-Host "[SPECIAL] Failed to log out: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "sleep" = @{
            Description = "Put the computer to sleep"
            Code = {
                try {
                    rundll32.exe powrprof.dll,SetSuspendState 0,1,0
                } catch {
                    Write-Host "[SPECIAL] Failed to sleep: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "lock" = @{
            Description = "Lock the workstation"
            Code = {
                try {
                    rundll32.exe user32.dll,LockWorkStation
                } catch {
                    Write-Host "[SPECIAL] Failed to lock: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "reboot" = @{
            Description = "Reboot the computer"
            Code = {
                try {
                    Restart-Computer -Force
                } catch {
                    Write-Host "[SPECIAL] Failed to reboot: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "hibernate" = @{
            Description = "Hibernate the computer"
            Code = {
                try {
                    rundll32.exe powrprof.dll,SetSuspendState Hibernate
                } catch {
                    Write-Host "[SPECIAL] Failed to hibernate: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "pause" = @{
            Description = "Pause script execution until user input"
            Code = { Pause "Paused by user request. Press any key to continue..." }
        }
        "elevate" = @{
            Description = "Rerun the script as administrator (UAC prompt)"
            Code = { Elevate-Self }
        }
        "exit" = @{
            Description = "Exit Script"
            Code = { exit }
        }
        "powersaver" = @{
            Description = "Set Windows power plan to Power Saver"
            Code      = {
                try {
                    powercfg.exe /s a1841308-3541-4fab-bc81-f71556f20b4a
                    Write-Host "Power plan set to Power Saver"
                } catch {
                    Write-Host "[SPECIAL] Failed to set Power Saver power plan $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "balanced" = @{
            Description = "Set Windows power plan to Balanced"
            Code      = {
                try {
                    powercfg.exe /s 381b4222-f694-41f0-9685-ff5bb260df2e
                    Write-Host "Power plan set to Balanced"
                } catch {
                    Write-Host "[SPECIAL] Failed to set Balanced power plan $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        "highperformance" = @{
            Description = "Set Windows power plan to High Performance"
            Code      = {
                try {
                    powercfg.exe /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
                    Write-Host "Power plan set to High Performance"
                } catch {
                    Write-Host "[SPECIAL] Failed to set High Performance power plan $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
}
# Now set the 'all' actions after definition
$possibleActions["meta"]["all"].Actions = $possibleActions["clean"].Keys
$possibleActions["meta"]["default"].Description = ($possibleActions["meta"]["default"].Actions -join ", ")

# region FUNCTIONS
function Show-Help {
    $scriptFileName = Split-Path -Leaf $MyInvocation.MyCommand.Path
    $actionDescriptions = $possibleActions.Keys | ForEach-Object {
        $category = $_
        $possibleActions[$category].GetEnumerator() | ForEach-Object {
            "  $($_.Key)  -  $($_.Value.Description)"
        }
    } | Out-String
    Write-Host @"
Usage: .\$scriptFileName -Actions <action1,action2,...> [-default] [-skipUAC] [-WhiteListedUsers ...]

-Actions:         One or more of:
$actionDescriptions
-skipUAC:        Skip elevation prompt
-WhiteListedUsers: Users whose Downloads folder will not be cleaned
-Help:           Show this help message
"@
    exit
}
# region UTILS
function Elevate-Self {
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
function Pause ($message) {
    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$message")
    }
    else {
        Write-Host "$message" -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}
function Quote {
    process {
        Write-Output "`"$_`""
    }
}
function Clear-Directory {
    param (
        [string]$Path,
        [switch]$RemoveDir
    )

    $pathStr = $Path | Quote

    if (-not (Test-Path $Path)) {
        Write-Host "$pathStr does not exist" -ForegroundColor DarkGray
        return
    }
    if ($RemoveDir) {
        $removeStr = 'Remov'
        $removePath = $Path
    } else {
        $removeStr = 'Clean'
        $removePath = "$Path\\*"
    }
    Set-Title "$($removeStr)ing directory $pathStr"
    try {
        Remove-Item -Path $removePath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "$($removeStr)ed directory $pathStr"
    }
    catch {
        if ($_.Exception.Message -like "*because it is being used by another process*") {
            Write-Host "$($_.Exception.Message)" -ForegroundColor Yellow
        } else {
            Write-Host "Error $($removeStr)ing directory $pathStr - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
# endregion UTILS
# region PYTHON
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
# endregion PYTHON
# region NODEJS
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
# endregion NODEJS
# region WINDOWS
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
    # Get-Process -Name cleanmgr,dismhost -ErrorAction SilentlyContinue | Wait-Process

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
        # Downloads cleaning moved to Clear-Downloads
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
# endregion WINDOWS
# endregion FUNCTIONS
# region LOGIC

$allValidActions = @()
foreach ($cat in $possibleActions.Keys) {
    $allValidActions += $possibleActions[$cat].Keys
}
$allValidActions = $allValidActions | Select-Object -Unique
$invalidActions = $Actions | Where-Object { $_.ToLower() -notin ($allValidActions | ForEach-Object { $_.ToLower() }) }
if ($invalidActions | Select-Object -Unique | Where-Object { $_ }) {
    Write-Host "Invalid action(s): $(( $invalidActions | Select-Object -Unique | Where-Object { $_ } ) -join ', ')" -ForegroundColor Red
    Write-Host "Valid actions are: $($allValidActions -join ', ')" -ForegroundColor Yellow
    exit 1
}

$actionsToRun = @()
foreach ($action in $Actions) {
    switch ($action) {
        "all" {
            $actionsToRun += $possibleActions["clean"].Keys
        }
        "default" {
            if ($possibleActions.ContainsKey("meta") -and $possibleActions["meta"].ContainsKey("default")) {
                $actionsToRun += $possibleActions["meta"]["default"].Actions
            }
        }
        default {
            $actionsToRun += $action
        }
    }
}

# Remove duplicates and preserve order
$actionsToRun = $actionsToRun | Select-Object -Unique

Write-Host "The following actions will be run:" -ForegroundColor Cyan
$actionTable = @()
$stepNum = 1
foreach ($act in $actionsToRun) {
    foreach ($category in $possibleActions.Keys) {
        if ($possibleActions[$category].ContainsKey($act)) {
            $desc = $possibleActions[$category][$act].Description
            $actionTable += [PSCustomObject]@{
                Step = $stepNum
                Code = $act
                Description = $desc
            }
            $stepNum++
            break
        }
    }
}
$actionTable | Format-Table -AutoSize

# Run selected actions
foreach ($act in $actionsToRun) {
    $found = $false
    foreach ($category in $possibleActions.Keys) {
        if ($possibleActions[$category].ContainsKey($act)) {
            & $possibleActions[$category][$act].Code
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Host "Unknown action $act" -ForegroundColor Red
    }
}

if ($PauseBeforeExit) {
    Pause "Press any key to exit"
}
# endregion LOGIC