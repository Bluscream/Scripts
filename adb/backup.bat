@echo off
setlocal enabledelayedexpansion

:: Set paths and timestamps
set TIMESTAMP=%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%_%TIME:~0,2%%TIME:~3,2%
set BACKUP_DIR=%USERPROFILE%\Desktop\AndroidBackup
set BACKUP_FILE=%BACKUP_DIR%\full_backup_%TIMESTAMP%.tar.gz

:: Create backup directory if it doesn't exist
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

echo Starting full device backup...
echo This process may take several minutes...

echo %BACKUP_FILE%

:: Execute the backup command
adb exec-out tar -cf - / 2>&1 | gzip > "%BACKUP_FILE%"
@REM  2>NUL

:: Check if backup was successful
if exist "%BACKUP_FILE%" (
    echo Backup completed!
    echo Backup file: %BACKUP_FILE%
    for %%v in ("%BACKUP_FILE%") do set "size=%%~zv"
    echo Size: !size! bytes
) else (
    echo Error: Backup failed - backup file not found!
)