param (
    [Parameter(Position = 0, Mandatory = $false)]
    # [ValidateSet(...)] removed for manual validation
    [string[]]$Actions = @(),
    [switch]$SkipUAC = $false,
    [string[]]$WhitelistedUsers = @("Bluscream"),
    [string]$Message = "Message",
    [switch]$Wait = $false
)

# Import Bluscream helper functions (must come first)
. "$PSScriptRoot/powershell/bluscream.ps1"
# Import the shared steps logic (depends on bluscream.ps1)
. "$PSScriptRoot/powershell/steps.ps1"

# --- Space Tracking ---
$Global:TotalSpaceSaved = 0

function Get-PathSize {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    if (Test-Path $Path -PathType Leaf) {
        return (Get-Item $Path).Length
    }
    return (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
}

function Format-Size {
    param ([long]$Bytes)
    if ($Bytes -le 0) { return "0 Bytes" }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes Bytes"
}

# Override Clear-Directory to track space
function Clear-Directory {
    param (
        [string]$Path,
        [switch]$RemoveDir
    )
    if (Test-Path $Path) {
        $size = Get-PathSize -Path $Path
        $Global:TotalSpaceSaved += $size
        $pathStr = $Path | Quote
        if ($size -gt 0) {
            Write-Host "Tracking $(Format-Size $size) to be saved from $pathStr" -ForegroundColor Gray
        }
        
        # Original logic from bluscream.ps1 (re-implemented here to track)
        if ($RemoveDir) {
            $removeStr = 'Remov'
            $removePath = $Path
        } else {
            $removeStr = 'Clean'
            $removePath = "$Path\*"
        }
        Set-Title "$($removeStr)ing directory $pathStr"
        try {
            Remove-Item -Path $removePath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "$($removeStr)ed directory $pathStr"
        } catch {
            if ($_.Exception.Message -like "*because it is being used by another process*") {
                Write-Host $($_.Exception.Message) -ForegroundColor Yellow
            } else {
                Write-Host "Error $($removeStr)ing directory $pathStr - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# --- Cleaning function definitions ---
function Invoke-PipCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Arguments
    )
    $commands = @(
        "pip",
        "python -m pip",
        "python3 -m pip",
        "C:\Users\Bluscream\.pyenv\pyenv-win\versions\3.14.0a4\python.exe -m pip"
    )
    foreach ($cmd in $commands) {
        try {
            # Split command and arguments for correct invocation
            $cmdParts = $cmd -split ' '
            $exe = $cmdParts[0]
            $cmdArgs = @()
            if ($cmdParts.Count -gt 1) {
                $cmdArgs += $cmdParts[1..($cmdParts.Count - 1)]
            }
            $allArgs = $cmdArgs + ($Arguments -split ' ')
            Write-Verbose "Running command: $exe $($allArgs -join ' ')"
            $output = & $exe @allArgs 2>&1
            if ($LASTEXITCODE -eq 0 -and $output) {
                return $output
            }
        } catch {
            Write-Verbose "Failed to run pip command: $_"
        }
    }
    Write-Warning "Failed to run pip command: $Arguments"
}

function Backup-Pip {
    Set-Title "Backing up pip packages"
    $pipList = Invoke-PipCommand -Arguments "list --format=freeze"
    if (-not $pipList) {
        Write-Warning "Could not retrieve pip package list. Skipping backup."
        return
    }
    $backupFilePath = "requirements.txt"
    $pipList | Out-File -FilePath $backupFilePath -Encoding utf8
    Write-Host "Pip packages have been backed up to $backupFilePath"
}
function Clear-Pip {
    $packageWhitelist = "wheel", "setuptools", "pip"
    Set-Title "Cleaning pip packages except ($packageWhitelist)"
    $pipList = Invoke-PipCommand -Arguments "list --format=freeze"
    if (-not $pipList) {
        Write-Warning "Could not retrieve pip package list. Skipping uninstall."
        return
    }
    $allPackages = $pipList | ForEach-Object { $_.Split('==')[0] }
    $unimportantPackages = $allPackages | Where-Object { $_ -and ($_ -notin $packageWhitelist) }
    if ($unimportantPackages.Count -gt 0) {
        try {
            Invoke-PipCommand -Arguments ("uninstall -y " + ($unimportantPackages -join ' '))
        } catch {
            Write-Warning "Bulk uninstall failed: $_. Attempting to uninstall packages individually."
            foreach ($package in $unimportantPackages) {
                try {
                    Invoke-PipCommand -Arguments "uninstall -y $package"
                } catch {
                    Write-Warning "Failed to uninstall package $($package): $_"
                }
            }
        }
    } else {
        Write-Host "Only important packages remain"
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
                        $size = Get-PathSize -Path $item.FullName
                        if ($item.PSIsContainer) {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        } else {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        }
                        $Global:TotalSpaceSaved += $size
                        Write-Host "Moved to Recycle Bin: $($item.FullName) ($(Format-Size $size))"
                    } catch {
                        Write-Host "Failed to move to Recycle Bin: $($item.FullName) - $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
            }
        }
    }
}
function Clear-Drives {
    Write-Host "Running Disk Cleanup for all fixed drives..."
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $driveLetter = $_.DeviceID
        Write-Host "Cleaning drive $driveLetter..."
        $processArgs = @{
            FilePath     = "CleanMgr.exe"
            ArgumentList = "/d $driveLetter /VERYLOWDISK"
            Wait         = $Wait
        }
        if ($Wait) {
            $processArgs.WindowStyle = "Normal"
        } else {
            $processArgs.WindowStyle = "Minimized"
        }
        Start-Process @processArgs
    }
}

function Clear-DrivesAlt {
    Set-Title "Cleaning Drives (Legacy Method)"
    Write-Host "Setting registry flags for Disk Cleanup..."
    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*' | ForEach-Object {
        try {
            New-ItemProperty -Path $_.PSPath -Name "StateFlags0001" -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
    Write-Host "Running Disk Cleanup sagerun:1..."
    $processArgs = @{
        FilePath     = "CleanMgr.exe"
        ArgumentList = "/sagerun:1"
        Wait         = $Wait
    }
    if ($Wait) {
        $processArgs.WindowStyle = "Normal"
    } else {
        $processArgs.WindowStyle = "Minimized"
    }
    Start-Process @processArgs
}
function Clear-Windows {
    Set-Title "Cleaning Windows"
    Write-Host "Stopping Windows Update Service"
    net stop wuauserv

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
    }
    Clear-Directory -Path "$env:windir\Temp"
    Clear-Directory -Path "$env:windir\Prefetch"
    if (Test-Path "$env:windir\memory.dmp") {
        $Global:TotalSpaceSaved += Get-PathSize -Path "$env:windir\memory.dmp"
        Remove-Item -Path "$env:windir\memory.dmp" -Force
    }
    Clear-Directory -Path "$env:windir\SoftwareDistribution"
    Clear-Directory -Path "G:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\"
    Write-Host "Starting Windows Update Service"
    net start wuauserv
}

function Clear-Dism {
    Set-Title "DISM Cleanup"
    Write-Host "Running DISM Component Store Cleanup (this may take several minutes)..."
    try {
        $processArgs = @{
            FilePath     = "Dism.exe"
            ArgumentList = "/online /Cleanup-Image /StartComponentCleanup /ResetBase"
            Wait         = $Wait
        }
        if ($Wait) {
            $processArgs.NoNewWindow = $true
        } else {
            $processArgs.WindowStyle = "Minimized"
        }
        Start-Process @processArgs
    } catch {
        Write-Warning "DISM cleanup failed: $_"
    }
}

function Clear-ShellBags {
    Set-Title "Shell Bags Cleanup"
    Write-Host "Flushing Explorer Shell Bags (Folder View Settings)..."
    $bags = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags"
    $bagMRU = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU"
    if (Test-Path $bags) { Remove-Item -Path $bags -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $bagMRU) { Remove-Item -Path $bagMRU -Recurse -Force -ErrorAction SilentlyContinue }
}

function Clear-AppLeftovers {
    Set-Title "App Leftovers Cleanup"
    Write-Host "Cleaning application leftovers..."
    $appLeftovers = @(
        "$env:LocalAppData\Microsoft\OneDrive",
        "$env:ProgramData\Microsoft OneDrive",
        "C:\Windows\Installer\Razer"
    )
    foreach ($path in $appLeftovers) {
        if (Test-Path $path) {
            Write-Host "Cleaning $path"
            Clear-Directory -Path $path
        }
    }
}

function Clear-Bits {
    Set-Title "BITS Cleanup"
    Write-Host "Clearing BITS Transfer Queue..."
    Stop-Service -Name BITS -Force -ErrorAction SilentlyContinue
    $bitsPath = "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader"
    if (Test-Path $bitsPath) {
        Get-ChildItem -Path $bitsPath -Filter "qmgr*.dat" | ForEach-Object {
            $Global:TotalSpaceSaved += $_.Length
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Service -Name BITS -ErrorAction SilentlyContinue
}
function Clear-Gpu {
    Set-Title "Cleaning GPU caches"
    $users = Get-ChildItem -Path $env:SystemDrive\Users -Directory
    foreach ($user in $users) {
        $nvidiaCacheFolders = @("DXCache", "GLCache", "OptixCache")
        foreach ($cacheFolder in $nvidiaCacheFolders) {
            $nvidiaPath = Join-Path -Path $user.FullName -ChildPath "AppData\Local\NVIDIA\$cacheFolder"
            Clear-Directory -Path $nvidiaPath
        }
    }
    Clear-Directory -Path "D:\_TEMP\AMD\DX9Cache"
    Clear-Directory -Path "D:\_TEMP\AMD\DxCache"
    Clear-Directory -Path "D:\_TEMP\AMD\DxcCache"
    Clear-Directory -Path "D:\_TEMP\AMD\OglCache"
    Clear-Directory -Path "D:\_TEMP\AMD\VkCache"
    Clear-Directory -Path "D:\_TEMP\AMD\amdcc"
}
function Clear-Games {
    Set-Title "Cleaning Game caches"
    Clear-Directory -Path "D:\_TEMP\VRChat\Cache-WindowsPlayer"
    Clear-Directory -Path "D:\_TEMP\VRChat\HTTPCache-WindowsPlayer"
    Clear-Directory -Path "D:\_TEMP\VRChat\TextureCache-WindowsPlayer"
    Clear-Directory -Path "D:\OneDrive\Games\VRChat\_TOOLS\VRCVideoCacher\CachedAssets"
    Clear-Directory -Path "D:\Users\Bluscream\AppData\LocalLow\VRChat\vrchat\HTTPCache-WindowsPlayer"
    Clear-Directory -Path "D:\Users\Bluscream\AppData\LocalLow\VRChat\vrchat\VRCHTTPCache"
    Clear-Directory -Path "S:\Steam\steamapps\common\ChilloutVR\ChilloutVR_Data\Cache\"
}
function Clear-WindowsEventlogs {
    Set-Title "Cleaning Windows event logs"
    $LogNames = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LogName
    Write-Host "Cleaning $($LogNames.Count) event logs"
    $cleaned = 0
    foreach ($LogName in $LogNames) {
        try {
            Start-Process -FilePath "wevtutil.exe" -ArgumentList "cl `"$LogName`"" -NoNewWindow # -WindowStyle Hidden  -Wait
            $cleaned++
        } catch {
            $errStr = "Failed to clear $LogName. Error: $_"
            Write-Host -NoNewline $errStr
        }
    }
    Write-Host "Successfully cleaned $cleaned/$($LogNames.Count) logs"
}
function Clear-Desktop {
    Set-Title "Cleaning Desktop files"
    
    # Define target directories
    $shortcutsDir = "D:\Desktop\_SHORTCUTS"
    $desktopDir = "D:\Desktop\"
    
    # Create target directories if they don't exist
    if (-not (Test-Path $shortcutsDir)) {
        New-Item -ItemType Directory -Path $shortcutsDir -Force | Out-Null
        Write-Host "Created directory: $shortcutsDir" -ForegroundColor Green
    }
    if (-not (Test-Path $desktopDir)) {
        New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
        Write-Host "Created directory: $desktopDir" -ForegroundColor Green
    }
    
    # Define desktop paths to clean
    $desktopPaths = @(
        [Environment]::GetFolderPath("Desktop"),  # Current user desktop
        [Environment]::GetFolderPath("CommonDesktopDirectory")  # Global desktop
    )
    
    $shortcutExtensions = @("*.url", "*.lnk", "*.symlink")
    $movedShortcuts = 0
    $movedFiles = 0
    
    foreach ($desktopPath in $desktopPaths) {
        if (-not (Test-Path $desktopPath)) {
            Write-Host "Desktop path not found: $desktopPath" -ForegroundColor DarkGray
            continue
        }
        
        Write-Host "Processing desktop: $desktopPath" -ForegroundColor Cyan
        
        # Get all files on desktop
        $files = Get-ChildItem -Path $desktopPath -File -Force
        
        foreach ($file in $files) {
            try {
                $isShortcut = $false
                
                # Check if file is a shortcut type
                foreach ($extension in $shortcutExtensions) {
                    if ($file.Name -like $extension) {
                        $isShortcut = $true
                        break
                    }
                }
                
                $targetPath = if ($isShortcut) { 
                    Join-Path -Path $shortcutsDir -ChildPath $file.Name
                    $movedShortcuts++
                } else { 
                    Join-Path -Path $desktopDir -ChildPath $file.Name
                    $movedFiles++
                }
                
                # Handle duplicate names
                $counter = 1
                $originalTargetPath = $targetPath
                while (Test-Path $targetPath) {
                    $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                    $extension = [System.IO.Path]::GetExtension($file.Name)
                    $targetPath = Join-Path -Path (Split-Path $originalTargetPath -Parent) -ChildPath "${nameWithoutExt}_${counter}${extension}"
                    $counter++
                }
                
                # Move the file
                Move-Item -Path $file.FullName -Destination $targetPath -Force
                $fileType = if ($isShortcut) { "shortcut" } else { "file" }
                Write-Host "Moved $fileType`: $($file.Name) -> $targetPath" -ForegroundColor Green
            } catch {
                Write-Host "Failed to move file: $($file.FullName) - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    Write-Host "Desktop cleaning completed:" -ForegroundColor Cyan
    Write-Host "  - Moved $movedShortcuts shortcut files to $shortcutsDir" -ForegroundColor Green
    Write-Host "  - Moved $movedFiles other files to $desktopDir" -ForegroundColor Green
}

# Extend or override $possibleSteps directly
$possibleSteps["clean"] = @{
    "pip"       = @{
        Description = "Clean pip cache and packages"
        Code        = { Backup-Pip; Clear-Pip }
    }
    "drivesalt" = @{
        Description = "Clean drives using legacy registry flags method"
        Code        = { Clear-DrivesAlt }
    }
    "npm"       = @{
        Description = "Clean npm cache and node_modules"
        Code        = { Backup-Npm; Clear-Npm }
    }
    "windows"   = @{
        Description = "Clean Windows temp files, caches, component store, shell bags, BITS, and event logs"
        Code        = { Clear-Drives; Clear-Dism; Clear-Windows; Clear-ShellBags; Clear-Bits; Clear-WindowsEventlogs }
    }
    "netdrives" = @{
        Description = "Remove mapped network drives"
        Code        = { Remove-MappedDrives }
    }
    "downloads" = @{
        Description = "Clean Downloads folders for all users except whitelisted ones"
        Code        = { Clear-Downloads }
    }
    "desktop"   = @{
        Description = "Clean desktop files - move shortcuts to D:\Desktop\_SHORTCUTS and other files to D:\Desktop\"
        Code        = { Clear-Desktop }
    }
    "gpu"       = @{
        Description = "Clean GPU caches (NVIDIA/AMD)"
        Code        = { Clear-Gpu }
    }
    "games"     = @{
        Description = "Clean game caches (VRChat/ChilloutVR)"
        Code        = { Clear-Games }
    }
    "leftovers" = @{
        Description = "Clean OneDrive/Razer residue"
        Code        = { Clear-AppLeftovers }
    }
}
$possibleSteps["meta"] = @{
    "all"     = @{
        Description = "Run all cleaning actions"
        Actions     = $possibleSteps["clean"].Keys
    }
    "default" = @{
        Description = "Default actions"
        Actions     = @("elevate", "pip", "npm", "windows", "gpu", "games", "pause")
    }
}

# To remove a special step, set it to null or use Remove:
# $possibleSteps["special"].Remove("shutdown")

# Expand actions (handle meta-actions)
$actionsToRun = Expand-Steps -Steps $possibleSteps -Actions $Actions

Write-Host "The following actions will be run:" -ForegroundColor Cyan

# Run the steps
Run-Steps -Steps $possibleSteps -ActionsToRun $actionsToRun

Write-Host "`nCleanup Summary" -ForegroundColor Cyan
Write-Host "----------------" -ForegroundColor Cyan
Write-Host "Total space saved (detected): $(Format-Size $Global:TotalSpaceSaved)" -ForegroundColor Green
Write-Host "Note: Background tasks (Disk Cleanup, DISM) may still be reclaiming additional space." -ForegroundColor Gray

if ($PauseBeforeExit) {
    Pause "Press any key to exit"
}
