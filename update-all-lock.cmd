@echo off
start "" "C:\Program Files\UniGetUI\UniGetUI.exe"
start "" powershell.exe -executionpolicy ByPass -File "C:\Scripts\update.ps1" -all
powercfg /setactive a1841308-3541-4fab-bc81-f71556f20b4a
Rundll32.exe user32.dll,LockWorkStation