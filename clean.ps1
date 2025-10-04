param (
    [Parameter(Position = 0, Mandatory = $false)]
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
        }
        catch {
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
        }
        catch {
            Write-Warning "Bulk uninstall failed: $_. Attempting to uninstall packages individually."
            foreach ($package in $unimportantPackages) {
                try {
                    Invoke-PipCommand -Arguments "uninstall -y $package"
                }
                catch {
                    Write-Warning "Failed to uninstall package $($package): $_"
                }
            }
        }
    }
    else {
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
        }
        catch {
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
                        }
                        else {
                            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                        }
                        Write-Host "Moved to Recycle Bin: $($item.FullName)"
                    }
                    catch {
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
    Write-Host "Cleaning $($LogNames.Count) event logs"
    $cleaned = 0
    foreach ($LogName in $LogNames) {
        try {
            Start-Process -FilePath "wevtutil.exe" -ArgumentList "cl `"$LogName`"" -NoNewWindow # -WindowStyle Hidden  -Wait
            $cleaned++
        }
        catch {
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
                }
                else { 
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
            }
            catch {
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
    "npm"       = @{
        Description = "Clean npm cache and node_modules"
        Code        = { Backup-Npm; Clear-Npm }
    }
    "windows"   = @{
        Description = "Clean Windows temp files, caches, and system folders"
        Code        = { Clear-Windows }
    }
    "eventlogs" = @{
        Description = "Clear Windows event logs"
        Code        = { Clear-WindowsEventlogs }
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
}
$possibleSteps["meta"] = @{
    "all"     = @{
        Description = "Run all cleaning actions"
        Actions     = $possibleSteps["clean"].Keys
    }
    "default" = @{
        Description = "Default actions"
        Actions     = @("elevate", "pip", "npm", "windows", "eventlogs", "pause")
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