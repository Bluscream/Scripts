# Set paths and filenames
$backupDir = "$env:USERPROFILE\Desktop\AndroidBackup"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFile = Join-Path $backupDir "full_backup_$timestamp.tar.gz"

# Create backup directory if it doesn't exist
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

Write-Host "Starting full device backup..."
Write-Host "This process may take several minutes..."#

$command = "exec-out tar -cf - / 2>&1 | gzip > '$backupFile'"
Write-Host "$command"

Start-Process adb.exe -ArgumentList "$command" -Wait -NoNewWindow

# Verify the backup file exists and get its size
if (Test-Path $backupFile) {
    $size = (Get-ChildItem $backupFile).Length
    Write-Host "Backup completed!"
    Write-Host "Backup file: $backupFile"
    Write-Host "Size: $((($size / 1024 / 1024) -as [int])) MB"
} else {
    Write-Error "Backup failed - backup file not found!"
}