param (
    [Parameter(Position=0, Mandatory=$false)]
    [ValidateSet("pip", "npm", "windows", "eventlogs", "netdrives", "default", "all")]
    [string[]]$Actions = @(),
    [switch]$SkipUAC = $false,
    [string[]]$WhitelistedUsers = @("Bluscream"),
    [switch]$Help
)

# region FUNCTIONS
function Show-Help {
    $scriptFileName = Split-Path -Leaf $MyInvocation.MyCommand.Path
    $actionDescriptions = $possibleActions.GetEnumerator() | ForEach-Object {
        "  $($_.Key)  -  $($_.Value.Description)"
    } | Out-String
    Write-Host @"
Usage: .\$scriptFileName -Actions <action1,action2,...> [-default] [-skipUAC] [-WhiteListedUsers ...]

-Actions:         One or more of:
$actionDescriptions
-default:        Run the default cleaning actions (pip, npm, windows, eventlogs)
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
        if ($WhitelistedUsers -notcontains $user.Name) {
            $downloadsDir = Join-Path -Path $user.FullName -ChildPath 'Downloads'
            if (Test-Path $downloadsDir) {
                Clear-Directory -Path $downloadsDir
            }
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
# endregion WINDOWS
# endregion FUNCTIONS
# region LOGIC

$possibleActions = @{
    "pip" = @{
        Description = "Clean pip cache and packages"
        Action      = { Backup-Pip; Clear-Pip }
    }
    "npm" = @{
        Description = "Clean npm cache and node_modules"
        Action      = { Backup-Npm; Clear-Npm }
    }
    "windows" = @{
        Description = "Clean Windows temp files, caches, and system folders"
        Action      = { Clear-Windows }
    }
    "eventlogs" = @{
        Description = "Clear Windows event logs"
        Action      = { Clear-WindowsEventlogs }
    }
    "netdrives" = @{
        Description = "Remove mapped network drives"
        Action      = { Remove-MappedDrives }
    }
    "all" = @{
        Description = "Run all cleaning actions"
        Action      = { foreach ($key in $possibleActions.Keys) { if ($key -ne "all" -and $key -ne "default") { & $possibleActions[$key].Action } } }
    }
    "default" = @{
        Description = "Run the default cleaning actions (pip, npm, windows, eventlogs)"
        Action      = { foreach ($key in @("pip", "npm", "windows", "eventlogs")) { & $possibleActions[$key].Action } }
    }
}

# Validate that the ValidateSet for -Actions matches the keys in $possibleActions
$param = $MyInvocation.MyCommand.Parameters["Actions"]
$validateSetValues = ($param.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
$possibleActionKeys = $possibleActions.Keys

# (Optional: Remove this check entirely, or use this order-insensitive version:)
if (-not ((@($validateSetValues) | Sort-Object) -join ',') -eq ((@($possibleActionKeys) | Sort-Object) -join ',')) {
    Write-Error "Mismatch between Actions ValidateSet and possibleActions keys. Please ensure they match."
    Write-Host "possibleActions keys: $($possibleActionKeys -join ', ')"
    Write-Host "Actions ValidateSet: $(@($validateSetValues) -join ', ')"
    exit 1
}

# Show help if requested or no action/default specified
if ($Help -or ($Actions.Count -eq 0 -and -not $Default)) {
    Show-Help
}

# Elevate if needed
if (-Not $SkipUAC) { Elevate-Self }

# Determine which actions to run
$actionsToRun = @()
if ($Actions -contains "all") {
    $actionsToRun = $possibleActions.Keys
} elseif ($Default) {
    $actionsToRun = @("pip", "npm", "windows", "eventlogs")
} else {
    $actionsToRun = $Actions
}

# Remove "all" and "default" from actionsToRun if present
$actionsToRun = $actionsToRun | Where-Object { $_ -ne "all" -and $_ -ne "default" }
$actionsToRun = $actionsToRun | Select-Object -Unique

Write-Host "The following actions will be run:" -ForegroundColor Cyan
$actionTable = @()
$stepNum = 1
foreach ($act in $actionsToRun) {
    if ($possibleActions.ContainsKey($act)) {
        $desc = $possibleActions[$act].Description
        $actionTable += [PSCustomObject]@{
            Step         = $stepNum
            Action       = $act
            Description  = $desc
        }
        $stepNum++
    }
}
$actionTable | Format-Table -AutoSize

exit

# Run selected actions
foreach ($act in $actionsToRun) {
    if ($possibleActions.ContainsKey($act)) {
        & $possibleActions[$act].Action
    }
}

if ($PauseBeforeExit) {
    Pause "Press any key to exit"
}
# endregion LOGIC