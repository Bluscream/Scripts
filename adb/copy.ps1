# CreateBackup.ps1
param (
    [string]$baseFolder = (Get-Location).Path,
    [switch]$Force
)

# Check if ADB is available
if (!(Get-Command adb -ErrorAction SilentlyContinue)) {
    Write-Host "ADB is not installed or not in PATH. Please install ADB tools." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $baseFolder)) {
    New-Item -ItemType Directory -Path $baseFolder -Force:$Force.IsPresent
}
# elseif ($Force.IsPresent) {
#     Get-ChildItem -Path $baseFolder | Remove-Item -Recurse -Force
# }

# Get device serial number
$deviceSerial = adb get-serialno
if ($LASTEXITCODE -ne 0) {
    Write-Host "No device connected or multiple devices detected. Please connect a single device." -ForegroundColor Red
    exit 1
}
Write-Host "Using device serial '$deviceSerial' for backup identification" -ForegroundColor Cyan
$backupFolder = Join-Path $baseFolder $deviceSerial
if (-not (Test-Path $backupFolder)) {
    New-Item -ItemType Directory -Path $backupFolder -Force:$Force.IsPresent
}

# Ask user if they want to save dumpsys information
$saveDumpsys = Read-Host "Do you want to save device dumpsys information? (y/n)"
if ($saveDumpsys -eq 'y' -or $saveDumpsys -eq 'Y') {
    Write-Host "Collecting dumpsys information..." -ForegroundColor Cyan
    $dumpsysFolder = Join-Path $backupFolder "dumpsys"
    if (-not (Test-Path $dumpsysFolder)) {
        New-Item -ItemType Directory -Path $dumpsysFolder -Force:$Force.IsPresent
    }
    
    # Get list of all dumpsys services
    $services = adb shell "dumpsys -l" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    
    foreach ($service in $services) {
        $serviceName = $service.Trim()
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
            Write-Host "Saving dumpsys for $serviceName..." -ForegroundColor Yellow
            $outputFile = Join-Path $dumpsysFolder "$serviceName.txt"
            adb shell "dumpsys $serviceName" | Out-File -FilePath $outputFile -Encoding utf8
        }
    }
    
    Write-Host "Dumpsys information saved to $dumpsysFolder" -ForegroundColor Green

    
    Write-Host "Getting device information..."
    $deviceInfo = adb shell "dumpsys"
    $deviceInfoPath = Join-Path $backupFolder "dumpsys.txt"
    $deviceInfo | Out-File -FilePath $deviceInfoPath -Encoding utf8 -Force
}


Write-Host "Device connected: $(adb devices | Select-String 'device$') ($deviceSerial)" -ForegroundColor Green

Write-Host "Getting list of root directories..." -ForegroundColor Cyan
$backupFolders = adb shell "ls /" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
Write-Host "Found $(($backupFolders | Measure-Object).Count) root directories to backup" -ForegroundColor Green

# Define an array of patterns to skip in output messages
$skipLines = @(
    "*: Permission denied",
    "adb: warning: skipping special file '*",
    "*: Input/output error"
)



foreach ($folder in $backupFolders) {
    # Skip the proc directory as it contains virtual files
    if ($folder -eq "proc") {
        Write-Host "Skipping proc directory (contains virtual files)..." -ForegroundColor Yellow
        continue
    }
    Write-Host "Backing up $folder..."
    $localFolder = Join-Path $backupFolder $folder # .Replace("/", "-")
    New-Item -ItemType Directory -Path $localFolder -Force:$Force.IsPresent
    adb pull "$folder" "$localFolder" 2>&1 | ForEach-Object {
        foreach ($pattern in $skipLines) {
            if ($_ -like $pattern) {
                continue
            }
        }
        Write-Host $_ # -ForegroundColor Yellow
    }
}

Write-Host "Creating full backup using adb backup command..." -ForegroundColor Cyan # Create a full backup using adb backup command
$backupFilePath = Join-Path $backupFolder "fullbackup.ab"
Write-Host "Backup will be saved to: $backupFilePath" -ForegroundColor Yellow
Write-Host "Please confirm the backup on your device when prompted." -ForegroundColor Magenta
$backupCommand = "backup -apk -obb -shared -all -system -f `"$backupFilePath`"" # Run the adb backup command with all options
Write-Host "Executing: adb $backupCommand" -ForegroundColor Gray
adb $backupCommand
# Check if backup was successful
if (Test-Path $backupFilePath) {
    $backupSize = (Get-Item $backupFilePath).Length
    $backupSizeMB = [math]::Round($backupSize / 1MB, 2)
    Write-Host "Full backup completed successfully!" -ForegroundColor Green
    Write-Host "Backup file size: $backupSizeMB MB" -ForegroundColor Green
} else {
    Write-Host "Full backup failed or was cancelled." -ForegroundColor Red
}

Write-Host "Backup completed!" -ForegroundColor Green