$ErrorActionPreference = "Continue"
$PSVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell Version: $($PSVersion.ToString())"
function Clear-AndDisable-EventLog {
    param(
        [string]$LogName
    )
    try {
        $logExists = $false
        try {
            $null = Get-WinEvent -ListLog $LogName -ErrorAction Stop
            $logExists = $true
        }
        catch {
            try {
                $null = Get-EventLog -List | Where-Object { $_.Log -eq $LogName }
                $logExists = $true
            }
            catch {
                $logExists = $false
            }
        }
        
        if ($logExists) {
            # Clear the event log
            $clearResult = & wevtutil cl "`"$LogName`"" 2>&1
            
            # Disable the event log
            $disableResult = & wevtutil sl "`"$LogName`"" /e:false 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "`"$LogName`" - DISABLED"
            }
            else {
                Write-Host "`"$LogName`"  - ENABLED (failed to disable)"
            }
        }
        else {
            Write-Host "`"$LogName`" - NOT FOUND"
        }
    }
    catch {
        Write-Host "`"$LogName`" - ERROR: $($_.Exception.Message)"
    }
}
Write-Host "Starting Event Log Clear and Disable Process"
Write-Host "============================================="
Write-Host ""
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: This script must be run as Administrator!"
    Write-Host "Please right-click PowerShell and select 'Run as Administrator'"
    exit 1
}
Write-Host "? Running with Administrator privileges"
Write-Host ""
Write-Host "Retrieving list of event logs..."
try {
    $eventLogs = @()
    try {
        Get-WinEvent -ListLog * | ForEach-Object {
            if ($_.LogName) {
                $eventLogs += $_.LogName
            }
        }
    }
    catch {
        Write-Host "Get-WinEvent failed, trying alternative method..."
        $eventLogs = @("Application", "System", "Security", "Setup", "ForwardedEvents")
        try {
            Get-EventLog -List | ForEach-Object {
                if ($_.Log -and $eventLogs -notcontains $_.Log) {
                    $eventLogs += $_.Log
                }
            }
        }
        catch {
            Write-Host "Using basic event log list..."
        }
    }
    $eventLogs = $eventLogs | Sort-Object
    if ($eventLogs) {
        Write-Host "Found $($eventLogs.Count) event logs to process"
        Write-Host ""
        foreach ($log in $eventLogs) {
            Clear-AndDisable-EventLog -LogName $log
        }
        Write-Host ""
        Write-Host "Event log processing completed!"
    }
    else {
        Write-Host "No event logs found!"
    }
}
catch {
    Write-Host "ERROR: Failed to retrieve event logs: $($_.Exception.Message)"
    exit 1
}