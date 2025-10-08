#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepares the system for MSI installation by clearing stuck installer states.

.DESCRIPTION
    This script clears all known "installation in progress" registry keys and kills
    remaining installer processes to ensure a clean state for MSI installations.
    It also checks and repairs the Windows Installer service if it's corrupted or disabled.

.PARAMETER Force
    Removes temporary installer files and rollback files. Also forces service repair.

.PARAMETER NoRestart
    Skips restarting the Windows Installer service after cleanup.

.PARAMETER RepairService
    Forces re-registration of the Windows Installer service even if it appears healthy.

.NOTES
    Author: Bluscream
    Requires: Administrator privileges
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoRestart,
    [switch]$RepairService
)

$ErrorActionPreference = 'Continue'
$VerbosePreference = 'Continue'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "MSI Installation Preparation Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script requires Administrator privileges. Please run as Administrator."
    exit 1
}

# Function to display full service registry configuration
function Show-ServiceRegistryConfig {
    param(
        [string]$Title = "Service Registry Configuration"
    )
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\msiserver"
    
    try {
        if (Test-Path $regPath) {
            $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
            
            Write-Host "`nRegistry Path: $regPath" -ForegroundColor White
            Write-Host "`nKey Properties:" -ForegroundColor Yellow
            
            # Important values to display
            $importantKeys = @(
                @{Name = 'ImagePath'; Description = 'Service Executable' },
                @{Name = 'DisplayName'; Description = 'Display Name' },
                @{Name = 'Description'; Description = 'Service Description' },
                @{Name = 'Start'; Description = 'Startup Type'; Values = @{0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' } },
                @{Name = 'Type'; Description = 'Service Type'; Values = @{1 = 'Kernel Driver'; 2 = 'File System Driver'; 16 = 'Own Process'; 32 = 'Share Process' } },
                @{Name = 'ErrorControl'; Description = 'Error Control'; Values = @{0 = 'Ignore'; 1 = 'Normal'; 2 = 'Severe'; 3 = 'Critical' } },
                @{Name = 'ObjectName'; Description = 'Log On As' },
                @{Name = 'DependOnService'; Description = 'Dependencies' },
                @{Name = 'FailureActions'; Description = 'Failure Actions' }
            )
            
            foreach ($key in $importantKeys) {
                $value = $props.($key.Name)
                if ($null -ne $value) {
                    $displayValue = $value
                    
                    # Translate numeric values if mapping exists
                    if ($key.ContainsKey('Values') -and $key.Values -is [hashtable] -and $key.Values.ContainsKey($value)) {
                        $displayValue = "$value ($($key.Values[$value]))"
                    }
                    
                    # Handle byte arrays
                    if ($value -is [byte[]]) {
                        $displayValue = "[Binary Data - $($value.Length) bytes]"
                    }
                    
                    # Color code based on value
                    $color = 'Gray'
                    if ($key.Name -eq 'ImagePath' -and [string]::IsNullOrWhiteSpace($value)) {
                        $color = 'Red'
                        $displayValue = '[EMPTY - CORRUPTED]'
                    }
                    elseif ($key.Name -eq 'Start' -and [string]::IsNullOrWhiteSpace($value)) {
                        $color = 'Red'
                        $displayValue = '[EMPTY - CORRUPTED]'
                    }
                    elseif ($key.Name -eq 'ImagePath' -or $key.Name -eq 'Start') {
                        $color = 'Green'
                    }
                    
                    Write-Host "  $($key.Description) ($($key.Name)): " -NoNewline -ForegroundColor White
                    Write-Host "$displayValue" -ForegroundColor $color
                }
                else {
                    Write-Host "  $($key.Description) ($($key.Name)): " -NoNewline -ForegroundColor White
                    Write-Host "[Not Set]" -ForegroundColor DarkGray
                }
            }
            
            # Show WMI view
            Write-Host "`nWMI/CIM Service View:" -ForegroundColor Yellow
            $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
            if ($serviceCim) {
                Write-Host "  PathName: " -NoNewline -ForegroundColor White
                if ([string]::IsNullOrWhiteSpace($serviceCim.PathName)) {
                    Write-Host "[EMPTY - CORRUPTED]" -ForegroundColor Red
                }
                else {
                    Write-Host "$($serviceCim.PathName)" -ForegroundColor Green
                }
                
                Write-Host "  StartMode: " -NoNewline -ForegroundColor White
                if ($serviceCim.StartMode -eq 'Unknown') {
                    Write-Host "$($serviceCim.StartMode) [CORRUPTED]" -ForegroundColor Red
                }
                else {
                    Write-Host "$($serviceCim.StartMode)" -ForegroundColor Green
                }
                
                Write-Host "  State: " -NoNewline -ForegroundColor White
                Write-Host "$($serviceCim.State)" -ForegroundColor $(if ($serviceCim.State -eq 'Running') { 'Green' }elseif ($serviceCim.State -eq 'Stopped') { 'Gray' }else { 'Yellow' })
            }
            else {
                Write-Host "  [Cannot query service via WMI]" -ForegroundColor Red
            }
            
        }
        else {
            Write-Host "`n[!] Registry path does not exist: $regPath" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "`n[!] Error reading registry: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "`n========================================`n" -ForegroundColor Cyan
}

# Function to stop Windows Installer service and processes
function Stop-WindowsInstallerService {
    Write-Host "`n[0] Stopping Windows Installer Service..." -ForegroundColor Cyan

    # Kill all msiexec processes first
    Write-Host "  [→] Terminating all msiexec processes..." -ForegroundColor Yellow
    Get-Process -Name "msiexec" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Use CIM to check if service exists and is running
    try {
        $serviceCimCheck = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction Stop
        if ($serviceCimCheck.State -eq 'Running') {
            Write-Host "  [→] Stopping service using sc.exe..." -ForegroundColor Yellow
            sc.exe stop msiserver 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            Write-Host "  [✓] Windows Installer service stopped" -ForegroundColor Green
        }
        else {
            Write-Host "  [i] Windows Installer service was not running" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  [i] Cannot determine service state (may not exist or be corrupted)" -ForegroundColor Gray
    }

    # Verify all msiexec processes are gone
    $remainingProcs = Get-Process -Name "msiexec" -ErrorAction SilentlyContinue
    if ($remainingProcs) {
        Write-Host "  [→] Force killing remaining msiexec processes..." -ForegroundColor Yellow
        $remainingProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Write-Host "  [✓] All msiexec processes terminated" -ForegroundColor Green
    }
    else {
        Write-Host "  [✓] No msiexec processes running" -ForegroundColor Green
    }
}

# Function to check service health and determine if repair is needed
function Test-WindowsInstallerServiceHealth {
    $serviceNeedsRepair = $false
    $serviceCimInfo = $null
    $serviceAccessDenied = $false

    Write-Host "`n[1] Checking Windows Installer Service health..." -ForegroundColor Cyan

    # First, check via CIM (this usually works even when Get-Service fails)
    try {
        $serviceCimInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction Stop
        
        if ([string]::IsNullOrWhiteSpace($serviceCimInfo.PathName)) {
            Write-Host "  [!] Windows Installer service has EMPTY PathName (corrupted)" -ForegroundColor Red
            $serviceNeedsRepair = $true
        }
        elseif ($serviceCimInfo.StartMode -eq 'Disabled' -or $serviceCimInfo.StartMode -eq 'Unknown') {
            Write-Host "  [!] Windows Installer service StartMode is $($serviceCimInfo.StartMode)" -ForegroundColor Yellow
            $serviceNeedsRepair = $true
        }
        elseif ($script:RepairService -or $script:Force) {
            Write-Host "  [i] Forcing service repair (RepairService/Force flag)" -ForegroundColor Yellow
            $serviceNeedsRepair = $true
        }
        else {
            Write-Host "  [✓] Windows Installer service exists (StartMode: $($serviceCimInfo.StartMode))" -ForegroundColor Green
            Write-Host "  [i] PathName: $($serviceCimInfo.PathName)" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  [!] Cannot query Windows Installer service - severe corruption" -ForegroundColor Red
        $serviceNeedsRepair = $true
    }

    # Also try Get-Service to check for permission issues
    try {
        Get-Service -Name "msiserver" -ErrorAction Stop | Out-Null
    }
    catch {
        if ($_.Exception.Message -like "*PermissionDenied*") {
            Write-Host "  [!] Get-Service blocked: Permission Denied (ACL corruption)" -ForegroundColor Red
            $serviceAccessDenied = $true
            $serviceNeedsRepair = $true
        }
    }

    return @{
        NeedsRepair  = $serviceNeedsRepair
        CimInfo      = $serviceCimInfo
        AccessDenied = $serviceAccessDenied
    }
}

# Function to repair Windows Installer service
function Repair-WindowsInstallerService {
    param(
        [hashtable]$HealthCheck
    )

    Write-Host "`n  [→] Attempting to repair Windows Installer service..." -ForegroundColor Yellow
    
    # Check msiexec.exe exists
    $msiexecPath = "$env:SystemRoot\System32\msiexec.exe"
    if (-not (Test-Path $msiexecPath)) {
        Write-Host "  [!] msiexec.exe not found at $msiexecPath" -ForegroundColor Red
        Write-Host "  [i] Your Windows installation may be corrupted" -ForegroundColor Yellow
        return
    }

    $serviceCimInfo = $HealthCheck.CimInfo
    $serviceAccessDenied = $HealthCheck.AccessDenied

    # If PathName is empty or permissions are broken, go directly to recreation
    if ($serviceCimInfo -and ([string]::IsNullOrWhiteSpace($serviceCimInfo.PathName) -or $serviceAccessDenied)) {
        Write-Host "  [!] Service is severely corrupted (empty PathName or ACL issue)" -ForegroundColor Red
        Write-Host "  [→] Directly recreating service..." -ForegroundColor Yellow
        
        # Force stop all msiexec processes first
        Get-Process -Name "msiexec" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        # Delete the corrupted service using sc.exe
        Write-Host "  [→] Deleting corrupted service..." -ForegroundColor Yellow
        sc.exe delete msiserver 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        
        # Recreate the service with proper configuration
        Write-Host "  [→] Creating new service with correct configuration..." -ForegroundColor Yellow
        sc.exe create msiserver binPath= "$env:SystemRoot\System32\msiexec.exe /V" DisplayName= "Windows Installer" type= own start= demand error= normal obj= LocalSystem 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        
        # Set service description
        sc.exe description msiserver "Installs, modifies and removes applications provided as a Windows Installer (*.msi, *.msm, *.msp) package. If this service is disabled, any services that explicitly depend on it will fail to start." | Out-Null
        
        # Set proper security descriptor to fix ACL
        Write-Host "  [→] Setting proper service permissions..." -ForegroundColor Yellow
        sc.exe sdset msiserver "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)" | Out-Null
        Start-Sleep -Seconds 1
        
        # Fix registry permissions and set Start value (only if $RepairService is specified)
        if ($RepairService) {
            Write-Host "  [→] Fixing registry configuration..." -ForegroundColor Yellow
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\msiserver"
            try {
                # Grant full control to Administrators on the registry key
                $acl = Get-Acl -Path $regPath
                $identity = "BUILTIN\Administrators"
                $rights = [System.Security.AccessControl.RegistryRights]::FullControl
                $inheritance = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
                $propagation = [System.Security.AccessControl.PropagationFlags]::None
                $type = [System.Security.AccessControl.AccessControlType]::Allow
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule($identity, $rights, $inheritance, $propagation, $type)
                $acl.SetAccessRule($rule)
                Set-Acl -Path $regPath -AclObject $acl -ErrorAction Stop
                
                # Now set the Start value to 3 (Manual)
                Set-ItemProperty -Path $regPath -Name "Start" -Value 3 -Type DWord -ErrorAction Stop
                Write-Host "  [✓] Registry Start value set to 3 (Manual)" -ForegroundColor Green
                
                # Ensure other required values are set
                if (-not (Get-ItemProperty -Path $regPath -Name "ObjectName" -ErrorAction SilentlyContinue)) {
                    Set-ItemProperty -Path $regPath -Name "ObjectName" -Value "LocalSystem" -Type String -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-Host "  [!] Registry fix failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  [→] Trying alternative method with reg.exe..." -ForegroundColor Yellow
                
                # Use reg.exe as fallback (runs with different permissions)
                reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\msiserver" /v Start /t REG_DWORD /d 3 /f | Out-Null
                Start-Sleep -Seconds 1
            }
        }
        else {
            Write-Host "  [i] Skipping registry modifications (use -RepairService to modify service registry)" -ForegroundColor Gray
        }
        
        # Verify the recreated service
        Start-Sleep -Seconds 2
        $recreatedService = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
        if ($recreatedService) {
            $pathOk = -not [string]::IsNullOrWhiteSpace($recreatedService.PathName)
            $startModeOk = $recreatedService.StartMode -ne 'Unknown'
            
            if ($pathOk -and $startModeOk) {
                Write-Host "  [✓] Windows Installer service successfully recreated!" -ForegroundColor Green
                Write-Host "  [i] Service PathName: $($recreatedService.PathName)" -ForegroundColor Gray
                Write-Host "  [i] Service StartMode: $($recreatedService.StartMode)" -ForegroundColor Gray
            }
            else {
                Write-Host "  [!] Service partially fixed:" -ForegroundColor Yellow
                Write-Host "      PathName: $(if($pathOk){'OK'}else{'STILL EMPTY'})" -ForegroundColor $(if ($pathOk) { 'Green' }else { 'Red' })
                Write-Host "      StartMode: $($recreatedService.StartMode)" -ForegroundColor $(if ($startModeOk) { 'Green' }else { 'Red' })
            }
        }
        else {
            Write-Host "  [!] Service recreation may have failed - verify manually" -ForegroundColor Yellow
        }
    }
    else {
        # Try standard re-registration first
        Write-Host "  [→] Re-registering Windows Installer service..." -ForegroundColor Yellow
        
        # Unregister first
        Start-Process -FilePath $msiexecPath -ArgumentList "/unregserver" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
        
        # Re-register
        Start-Process -FilePath $msiexecPath -ArgumentList "/regserver" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
        
        # Verify
        $serviceInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
        if ($serviceInfo -and -not [string]::IsNullOrWhiteSpace($serviceInfo.PathName)) {
            Write-Host "  [✓] Windows Installer service successfully repaired!" -ForegroundColor Green
            Write-Host "  [i] Service PathName: $($serviceInfo.PathName)" -ForegroundColor Gray
        }
        else {
            Write-Host "  [!] Re-registration didn't work, trying recreation..." -ForegroundColor Yellow
            
            # Fall back to recreation (same as above)
            Get-Process -Name "msiexec" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            sc.exe delete msiserver 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            sc.exe create msiserver binPath= "$env:SystemRoot\System32\msiexec.exe /V" DisplayName= "Windows Installer" type= own start= demand error= normal obj= LocalSystem 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            sc.exe description msiserver "Installs, modifies and removes applications provided as a Windows Installer (*.msi, *.msm, *.msp) package. If this service is disabled, any services that explicitly depend on it will fail to start." | Out-Null
            sc.exe sdset msiserver "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)" | Out-Null
            
            # Fix registry Start value (only if $RepairService is specified)
            if ($RepairService) {
                Write-Host "  [→] Fixing registry Start value..." -ForegroundColor Yellow
                reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\msiserver" /v Start /t REG_DWORD /d 3 /f | Out-Null
                Start-Sleep -Seconds 2
            }
            else {
                Write-Host "  [i] Skipping registry modifications (use -RepairService to modify service registry)" -ForegroundColor Gray
            }
            
            $recreatedService = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
            if ($recreatedService) {
                $pathOk = -not [string]::IsNullOrWhiteSpace($recreatedService.PathName)
                $startModeOk = $recreatedService.StartMode -ne 'Unknown'
                
                if ($pathOk -and $startModeOk) {
                    Write-Host "  [✓] Windows Installer service successfully recreated!" -ForegroundColor Green
                    Write-Host "  [i] Service PathName: $($recreatedService.PathName)" -ForegroundColor Gray
                    Write-Host "  [i] Service StartMode: $($recreatedService.StartMode)" -ForegroundColor Gray
                }
                else {
                    Write-Host "  [!] Service partially fixed - PathName: $(if($pathOk){'OK'}else{'EMPTY'}), StartMode: $($recreatedService.StartMode)" -ForegroundColor Yellow
                }
            }
        }
    }
}

# Function to kill remaining installer processes
function Stop-InstallerProcesses {
    Write-Host "`n[2] Killing installer processes..." -ForegroundColor Cyan
    
    $installerProcesses = @(
        "msiexec",
        "setup",
        "install",
        "installer",
        "MsiExec",
        "InstallShield",
        "WindowsInstaller",
        "WUSA",
        "TrustedInstaller",
        "DPInst",
        "WixExec",
        "Uninstall",
        "uninst"
    )

    foreach ($procName in $installerProcesses) {
        Stop-InstallerProcess -ProcessName $procName
    }
}

# Function to clear installer registry keys
function Clear-InstallerRegistryKeys {
    Write-Host "`n[3] Clearing Windows Installer registry keys..." -ForegroundColor Cyan

    # Main InProgress key
    Write-Host "  Clearing InProgress keys..." -ForegroundColor White
    Clear-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress" -RemoveKey

    # Alternative InProgress locations
    $inProgressKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Installer\InProgress",
        "HKLM:\SOFTWARE\Classes\Installer\InProgress"
    )

    foreach ($key in $inProgressKeys) {
        Clear-RegistryKey -Path $key -RemoveKey
    }

    # Clear Session Manager PendingFileRenameOperations (cautiously)
    Write-Host "`n  Clearing pending file rename operations..." -ForegroundColor White
    Clear-RegistryKey -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations"
    Clear-RegistryKey -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations2"

    # Clear Windows Update Installer keys
    Write-Host "`n  Clearing Windows Update installer state..." -ForegroundColor White
    $wuKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending"
    )

    foreach ($key in $wuKeys) {
        Clear-RegistryKey -Path $key -RemoveKey
    }

    # Clear installer RunOnce keys that might block installations
    Write-Host "`n  Clearing installer RunOnce keys..." -ForegroundColor White
    $runOnceKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    )

    foreach ($key in $runOnceKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($prop in $props.PSObject.Properties) {
                    if ($prop.Name -notlike 'PS*' -and $prop.Value -like '*msi*' -or $prop.Value -like '*install*') {
                        Clear-RegistryKey -Path $key -Name $prop.Name
                    }
                }
            }
        }
    }
}

# Function to check and clear Windows Installer cache
function Clear-InstallerCache {
    Write-Host "`n[4] Checking Windows Installer cache..." -ForegroundColor Cyan
    
    $installerCache = "$env:SystemRoot\Installer"
    if (Test-Path $installerCache) {
        try {
            # Check for orphaned rollback folders
            $rollbackFolders = Get-ChildItem -Path $installerCache -Filter "*.rbf" -ErrorAction SilentlyContinue
            if ($rollbackFolders) {
                Write-Host "  [i] Found $($rollbackFolders.Count) rollback files" -ForegroundColor Gray
                if ($script:Force) {
                    foreach ($rbf in $rollbackFolders) {
                        Remove-Item $rbf.FullName -Force -ErrorAction SilentlyContinue
                        Write-Host "  [✓] Removed rollback file: $($rbf.Name)" -ForegroundColor Green
                    }
                }
                else {
                    Write-Host "  [i] Use -Force to remove rollback files" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "  [!] Error checking installer cache: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Function to clear temporary installer files
function Clear-TempInstallerFiles {
    Write-Host "`n[5] Clearing temporary installer files..." -ForegroundColor Cyan
    
    $tempPaths = @(
        "$env:TEMP\*.msi",
        "$env:TEMP\*.msp",
        "$env:TEMP\*.mst",
        "$env:SystemRoot\Temp\*.msi",
        "$env:SystemRoot\Temp\*.msp",
        "$env:SystemRoot\Temp\*.mst"
    )

    foreach ($pattern in $tempPaths) {
        try {
            $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
            if ($files) {
                Write-Host "  [→] Found $($files.Count) files matching: $pattern" -ForegroundColor Gray
                if ($script:Force) {
                    foreach ($file in $files) {
                        Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                        Write-Host "  [✓] Removed: $($file.Name)" -ForegroundColor Green
                    }
                }
                else {
                    Write-Host "  [i] Use -Force to remove temp files" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "  [!] Error clearing temp files: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Function to start Windows Installer service
function Start-WindowsInstallerService {
    if ($script:NoRestart) {
        Write-Host "`n[6] Skipping service restart (NoRestart flag)" -ForegroundColor Yellow
        return
    }

    Write-Host "`n[6] Starting Windows Installer Service..." -ForegroundColor Cyan
    
    # Use sc.exe for more reliable starting (bypasses ACL issues)
    sc.exe start msiserver | Out-Null
    Start-Sleep -Seconds 2
    
    # Verify it started
    $serviceCimCheck = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
    if ($serviceCimCheck -and $serviceCimCheck.State -eq 'Running') {
        Write-Host "  [✓] Windows Installer service started" -ForegroundColor Green
    }
    elseif ($serviceCimCheck -and $serviceCimCheck.State -eq 'Stopped') {
        Write-Host "  [i] Service is configured but stopped (will start on-demand)" -ForegroundColor Gray
    }
    else {
        Write-Host "  [!] Could not verify service state" -ForegroundColor Yellow
        Write-Host "  [i] Service will start automatically when needed" -ForegroundColor Gray
    }
}

# Function to perform final status check
function Show-FinalStatus {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Status Check" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Check for remaining installer processes
    $allMsiexec = Get-Process -Name "msiexec" -ErrorAction SilentlyContinue

    if ($allMsiexec) {
        # Try to get command lines via WMI to distinguish service from installer instances
        $installerInstances = @()
        try {
            $wmiProcesses = Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue
            foreach ($proc in $wmiProcesses) {
                # Service instance has no command line args or just "/V"
                if ($proc.CommandLine -and $proc.CommandLine -notmatch "^.*msiexec\.exe[`"']?\s*(\/V)?\s*$") {
                    $installerInstances += $proc
                }
            }
        }
        catch {
            # If WMI fails, assume multiple instances = problem
            if ($allMsiexec.Count -gt 1) {
                $installerInstances = $allMsiexec
            }
        }
        
        if ($installerInstances.Count -gt 0) {
            Write-Host "[!] Warning: $($installerInstances.Count) active installer instance(s) detected" -ForegroundColor Yellow
        }
        elseif ($allMsiexec.Count -eq 1) {
            Write-Host "[✓] Only service msiexec.exe running (normal)" -ForegroundColor Green
        }
        else {
            Write-Host "[✓] Multiple service instances running (normal after restart)" -ForegroundColor Green
        }
    }
    else {
        Write-Host "[✓] No installer processes running" -ForegroundColor Green
    }

    # Check Windows Installer service
    try {
        $msiServiceFinal = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction Stop
        $pathValid = -not [string]::IsNullOrWhiteSpace($msiServiceFinal.PathName)
        $startModeValid = $msiServiceFinal.StartMode -ne 'Unknown'
        
        Write-Host "[i] Windows Installer service state: $($msiServiceFinal.State)" -ForegroundColor $(if ($msiServiceFinal.State -eq 'Stopped' -or $msiServiceFinal.State -eq 'Running') { 'Green' }else { 'Yellow' })
        Write-Host "[i] Service StartMode: $($msiServiceFinal.StartMode)" -ForegroundColor $(if ($startModeValid) { 'Green' }else { 'Yellow' })
        Write-Host "[i] Service PathName: $(if($pathValid){$msiServiceFinal.PathName}else{'[EMPTY - STILL CORRUPTED!]'})" -ForegroundColor $(if ($pathValid) { 'Green' }else { 'Red' })
    }
    catch {
        Write-Host "[!] Could not query Windows Installer service status" -ForegroundColor Red
    }

    # Check InProgress key
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress") {
        Write-Host "[!] Warning: InProgress key still exists" -ForegroundColor Yellow
    }
    else {
        Write-Host "[✓] InProgress key cleared" -ForegroundColor Green
    }
}

# Function to safely remove or clear registry keys
function Clear-RegistryKey {
    param(
        [string]$Path,
        [string]$Name = $null,
        [switch]$RemoveKey
    )
    
    try {
        if (Test-Path $Path) {
            if ($RemoveKey) {
                Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                Write-Host "  [✓] Removed: $Path" -ForegroundColor Green
            }
            elseif ($Name) {
                if (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue) {
                    Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
                    Write-Host "  [✓] Cleared: $Path\$Name" -ForegroundColor Green
                }
                else {
                    Write-Host "  [i] Not found: $Path\$Name" -ForegroundColor Gray
                }
            }
            else {
                # Clear all values under the key
                $properties = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
                if ($properties) {
                    foreach ($prop in $properties.PSObject.Properties) {
                        if ($prop.Name -notlike 'PS*') {
                            Remove-ItemProperty -Path $Path -Name $prop.Name -Force -ErrorAction SilentlyContinue
                        }
                    }
                    Write-Host "  [✓] Cleared all values: $Path" -ForegroundColor Green
                }
            }
        }
        else {
            Write-Host "  [i] Path not found: $Path" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  [!] Failed to clear: $Path - $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Function to kill processes safely
function Stop-InstallerProcess {
    param(
        [string]$ProcessName
    )
    
    try {
        $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($processes) {
            foreach ($proc in $processes) {
                Write-Host "  [→] Stopping: $ProcessName (PID: $($proc.Id))" -ForegroundColor Yellow
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Host "  [✓] Killed: $ProcessName (PID: $($proc.Id))" -ForegroundColor Green
            }
        }
        else {
            Write-Host "  [i] No running instances: $ProcessName" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  [!] Failed to kill $ProcessName - $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

# Store script parameters in script scope for function access
$script:Force = $Force
$script:NoRestart = $NoRestart
$script:RepairService = $RepairService

# Display BEFORE state
Show-ServiceRegistryConfig -Title "BEFORE: Current Service Configuration"

# Step 0: Stop Windows Installer Service FIRST
Stop-WindowsInstallerService

# Step 1: Check and repair Windows Installer Service if needed
$healthCheck = Test-WindowsInstallerServiceHealth
if ($healthCheck.NeedsRepair) {
    Repair-WindowsInstallerService -HealthCheck $healthCheck
}

# Step 2: Kill remaining installer processes
Stop-InstallerProcesses

# Step 3: Clear registry keys
Clear-InstallerRegistryKeys

# Step 4: Check Windows Installer cache
Clear-InstallerCache

# Step 5: Clear temp installer files
Clear-TempInstallerFiles

# Step 6: Start Windows Installer Service
Start-WindowsInstallerService

# Final status check and AFTER state
Show-FinalStatus

# Display AFTER state
Show-ServiceRegistryConfig -Title "AFTER: Final Service Configuration"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "MSI Installation preparation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nYou can now proceed with your MSI installation.`n" -ForegroundColor White
try {
    $serviceCimInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction Stop
    
    if ([string]::IsNullOrWhiteSpace($serviceCimInfo.PathName)) {
        Write-Host "  [!] Windows Installer service has EMPTY PathName (corrupted)" -ForegroundColor Red
        $serviceNeedsRepair = $true
    }
    elseif ($serviceCimInfo.StartMode -eq 'Disabled' -or $serviceCimInfo.StartMode -eq 'Unknown') {
        Write-Host "  [!] Windows Installer service StartMode is $($serviceCimInfo.StartMode)" -ForegroundColor Yellow
        $serviceNeedsRepair = $true
    }
    elseif ($RepairService -or $Force) {
        Write-Host "  [i] Forcing service repair (RepairService/Force flag)" -ForegroundColor Yellow
        $serviceNeedsRepair = $true
    }
    else {
        Write-Host "  [✓] Windows Installer service exists (StartMode: $($serviceCimInfo.StartMode))" -ForegroundColor Green
        Write-Host "  [i] PathName: $($serviceCimInfo.PathName)" -ForegroundColor Gray
    }
}
catch {
    Write-Host "  [!] Cannot query Windows Installer service - severe corruption" -ForegroundColor Red
    $serviceNeedsRepair = $true
}

# Also try Get-Service to check for permission issues
$serviceAccessDenied = $false
try {
    Get-Service -Name "msiserver" -ErrorAction Stop | Out-Null
}
catch {
    if ($_.Exception.Message -like "*PermissionDenied*") {
        Write-Host "  [!] Get-Service blocked: Permission Denied (ACL corruption)" -ForegroundColor Red
        $serviceAccessDenied = $true
        $serviceNeedsRepair = $true
    }
}

if ($serviceNeedsRepair) {
    Write-Host "`n  [→] Attempting to repair Windows Installer service..." -ForegroundColor Yellow
    
    # Check msiexec.exe exists
    $msiexecPath = "$env:SystemRoot\System32\msiexec.exe"
    if (-not (Test-Path $msiexecPath)) {
        Write-Host "  [!] msiexec.exe not found at $msiexecPath" -ForegroundColor Red
        Write-Host "  [i] Your Windows installation may be corrupted" -ForegroundColor Yellow
    }
    else {
        # If PathName is empty or permissions are broken, go directly to recreation
        if ($serviceCimInfo -and ([string]::IsNullOrWhiteSpace($serviceCimInfo.PathName) -or $serviceAccessDenied)) {
            Write-Host "  [!] Service is severely corrupted (empty PathName or ACL issue)" -ForegroundColor Red
            Write-Host "  [→] Directly recreating service..." -ForegroundColor Yellow
            
            # Force stop all msiexec processes first
            Get-Process -Name "msiexec" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            
            # Delete the corrupted service using sc.exe
            Write-Host "  [→] Deleting corrupted service..." -ForegroundColor Yellow
            sc.exe delete msiserver 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            
            # Recreate the service with proper configuration
            Write-Host "  [→] Creating new service with correct configuration..." -ForegroundColor Yellow
            sc.exe create msiserver binPath= "$env:SystemRoot\System32\msiexec.exe /V" DisplayName= "Windows Installer" type= own start= demand error= normal obj= LocalSystem 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            
            # Set service description
            sc.exe description msiserver "Installs, modifies and removes applications provided as a Windows Installer (*.msi, *.msm, *.msp) package. If this service is disabled, any services that explicitly depend on it will fail to start." | Out-Null
            
            # Set proper security descriptor to fix ACL
            Write-Host "  [→] Setting proper service permissions..." -ForegroundColor Yellow
            sc.exe sdset msiserver "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)" | Out-Null
            Start-Sleep -Seconds 1
            
            # Fix registry permissions and set Start value (only if $RepairService is specified)
            if ($RepairService) {
                Write-Host "  [→] Fixing registry configuration..." -ForegroundColor Yellow
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\msiserver"
                try {
                    # Grant full control to Administrators on the registry key
                    $acl = Get-Acl -Path $regPath
                    $identity = "BUILTIN\Administrators"
                    $rights = [System.Security.AccessControl.RegistryRights]::FullControl
                    $inheritance = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
                    $propagation = [System.Security.AccessControl.PropagationFlags]::None
                    $type = [System.Security.AccessControl.AccessControlType]::Allow
                    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($identity, $rights, $inheritance, $propagation, $type)
                    $acl.SetAccessRule($rule)
                    Set-Acl -Path $regPath -AclObject $acl -ErrorAction Stop
                    
                    # Now set the Start value to 3 (Manual)
                    Set-ItemProperty -Path $regPath -Name "Start" -Value 3 -Type DWord -ErrorAction Stop
                    Write-Host "  [✓] Registry Start value set to 3 (Manual)" -ForegroundColor Green
                    
                    # Ensure other required values are set
                    if (-not (Get-ItemProperty -Path $regPath -Name "ObjectName" -ErrorAction SilentlyContinue)) {
                        Set-ItemProperty -Path $regPath -Name "ObjectName" -Value "LocalSystem" -Type String -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    Write-Host "  [!] Registry fix failed: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "  [→] Trying alternative method with reg.exe..." -ForegroundColor Yellow
                    
                    # Use reg.exe as fallback (runs with different permissions)
                    reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\msiserver" /v Start /t REG_DWORD /d 3 /f | Out-Null
                    Start-Sleep -Seconds 1
                }
            }
            else {
                Write-Host "  [i] Skipping registry modifications (use -RepairService to modify service registry)" -ForegroundColor Gray
            }
            
            # Verify the recreated service
            Start-Sleep -Seconds 2
            $recreatedService = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
            if ($recreatedService) {
                $pathOk = -not [string]::IsNullOrWhiteSpace($recreatedService.PathName)
                $startModeOk = $recreatedService.StartMode -ne 'Unknown'
                
                if ($pathOk -and $startModeOk) {
                    Write-Host "  [✓] Windows Installer service successfully recreated!" -ForegroundColor Green
                    Write-Host "  [i] Service PathName: $($recreatedService.PathName)" -ForegroundColor Gray
                    Write-Host "  [i] Service StartMode: $($recreatedService.StartMode)" -ForegroundColor Gray
                }
                else {
                    Write-Host "  [!] Service partially fixed:" -ForegroundColor Yellow
                    Write-Host "      PathName: $(if($pathOk){'OK'}else{'STILL EMPTY'})" -ForegroundColor $(if ($pathOk) { 'Green' }else { 'Red' })
                    Write-Host "      StartMode: $($recreatedService.StartMode)" -ForegroundColor $(if ($startModeOk) { 'Green' }else { 'Red' })
                }
            }
            else {
                Write-Host "  [!] Service recreation may have failed - verify manually" -ForegroundColor Yellow
            }
        }
        else {
            # Try standard re-registration first
            Write-Host "  [→] Re-registering Windows Installer service..." -ForegroundColor Yellow
            
            # Unregister first
            Start-Process -FilePath $msiexecPath -ArgumentList "/unregserver" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2
            
            # Re-register
            Start-Process -FilePath $msiexecPath -ArgumentList "/regserver" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2
            
            # Verify
            $serviceInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
            if ($serviceInfo -and -not [string]::IsNullOrWhiteSpace($serviceInfo.PathName)) {
                Write-Host "  [✓] Windows Installer service successfully repaired!" -ForegroundColor Green
                Write-Host "  [i] Service PathName: $($serviceInfo.PathName)" -ForegroundColor Gray
            }
            else {
                Write-Host "  [!] Re-registration didn't work, trying recreation..." -ForegroundColor Yellow
                
                # Fall back to recreation (same as above)
                Get-Process -Name "msiexec" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                sc.exe delete msiserver 2>&1 | Out-Null
                Start-Sleep -Seconds 3
                sc.exe create msiserver binPath= "$env:SystemRoot\System32\msiexec.exe /V" DisplayName= "Windows Installer" type= own start= demand error= normal obj= LocalSystem 2>&1 | Out-Null
                Start-Sleep -Seconds 2
                sc.exe description msiserver "Installs, modifies and removes applications provided as a Windows Installer (*.msi, *.msm, *.msp) package. If this service is disabled, any services that explicitly depend on it will fail to start." | Out-Null
                sc.exe sdset msiserver "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)" | Out-Null
                
                # Fix registry Start value (only if $RepairService is specified)
                if ($RepairService) {
                    Write-Host "  [→] Fixing registry Start value..." -ForegroundColor Yellow
                    reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\msiserver" /v Start /t REG_DWORD /d 3 /f | Out-Null
                    Start-Sleep -Seconds 2
                }
                else {
                    Write-Host "  [i] Skipping registry modifications (use -RepairService to modify service registry)" -ForegroundColor Gray
                }
                
                $recreatedService = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
                if ($recreatedService) {
                    $pathOk = -not [string]::IsNullOrWhiteSpace($recreatedService.PathName)
                    $startModeOk = $recreatedService.StartMode -ne 'Unknown'
                    
                    if ($pathOk -and $startModeOk) {
                        Write-Host "  [✓] Windows Installer service successfully recreated!" -ForegroundColor Green
                        Write-Host "  [i] Service PathName: $($recreatedService.PathName)" -ForegroundColor Gray
                        Write-Host "  [i] Service StartMode: $($recreatedService.StartMode)" -ForegroundColor Gray
                    }
                    else {
                        Write-Host "  [!] Service partially fixed - PathName: $(if($pathOk){'OK'}else{'EMPTY'}), StartMode: $($recreatedService.StartMode)" -ForegroundColor Yellow
                    }
                }
            }
        }
    }
}

# Step 2: Kill remaining installer processes
Write-Host "`n[2] Killing installer processes..." -ForegroundColor Cyan
$installerProcesses = @(
    "msiexec",
    "setup",
    "install",
    "installer",
    "MsiExec",
    "InstallShield",
    "WindowsInstaller",
    "WUSA",
    "TrustedInstaller",
    "DPInst",
    "WixExec",
    "Uninstall",
    "uninst"
)

foreach ($procName in $installerProcesses) {
    Stop-InstallerProcess -ProcessName $procName
}

# Step 3: Clear registry keys
Write-Host "`n[3] Clearing Windows Installer registry keys..." -ForegroundColor Cyan

# Main InProgress key
Write-Host "  Clearing InProgress keys..." -ForegroundColor White
Clear-RegistryKey -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress" -RemoveKey

# Alternative InProgress locations
$inProgressKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Installer\InProgress",
    "HKLM:\SOFTWARE\Classes\Installer\InProgress"
)

foreach ($key in $inProgressKeys) {
    Clear-RegistryKey -Path $key -RemoveKey
}

# Clear Session Manager PendingFileRenameOperations (cautiously)
Write-Host "`n  Clearing pending file rename operations..." -ForegroundColor White
Clear-RegistryKey -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations"
Clear-RegistryKey -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations2"

# Clear Windows Update Installer keys
Write-Host "`n  Clearing Windows Update installer state..." -ForegroundColor White
$wuKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending"
)

foreach ($key in $wuKeys) {
    Clear-RegistryKey -Path $key -RemoveKey
}

# Clear installer RunOnce keys that might block installations
Write-Host "`n  Clearing installer RunOnce keys..." -ForegroundColor White
$runOnceKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
)

foreach ($key in $runOnceKeys) {
    if (Test-Path $key) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -notlike 'PS*' -and $prop.Value -like '*msi*' -or $prop.Value -like '*install*') {
                    Clear-RegistryKey -Path $key -Name $prop.Name
                }
            }
        }
    }
}

# Step 4: Check Windows Installer cache
Write-Host "`n[4] Checking Windows Installer cache..." -ForegroundColor Cyan
$installerCache = "$env:SystemRoot\Installer"
if (Test-Path $installerCache) {
    try {
        # Check for orphaned rollback folders
        $rollbackFolders = Get-ChildItem -Path $installerCache -Filter "*.rbf" -ErrorAction SilentlyContinue
        if ($rollbackFolders) {
            Write-Host "  [i] Found $($rollbackFolders.Count) rollback files" -ForegroundColor Gray
            if ($Force) {
                foreach ($rbf in $rollbackFolders) {
                    Remove-Item $rbf.FullName -Force -ErrorAction SilentlyContinue
                    Write-Host "  [✓] Removed rollback file: $($rbf.Name)" -ForegroundColor Green
                }
            }
            else {
                Write-Host "  [i] Use -Force to remove rollback files" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "  [!] Error checking installer cache: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Step 5: Clear temp installer files
Write-Host "`n[5] Clearing temporary installer files..." -ForegroundColor Cyan
$tempPaths = @(
    "$env:TEMP\*.msi",
    "$env:TEMP\*.msp",
    "$env:TEMP\*.mst",
    "$env:SystemRoot\Temp\*.msi",
    "$env:SystemRoot\Temp\*.msp",
    "$env:SystemRoot\Temp\*.mst"
)

foreach ($pattern in $tempPaths) {
    try {
        $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        if ($files) {
            Write-Host "  [→] Found $($files.Count) files matching: $pattern" -ForegroundColor Gray
            if ($Force) {
                foreach ($file in $files) {
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                    Write-Host "  [✓] Removed: $($file.Name)" -ForegroundColor Green
                }
            }
            else {
                Write-Host "  [i] Use -Force to remove temp files" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "  [!] Error clearing temp files: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Step 6: Start Windows Installer Service
if (-not $NoRestart) {
    Write-Host "`n[6] Starting Windows Installer Service..." -ForegroundColor Cyan
    
    # Use sc.exe for more reliable starting (bypasses ACL issues)
    sc.exe start msiserver | Out-Null
    Start-Sleep -Seconds 2
    
    # Verify it started
    $serviceCimCheck = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
    if ($serviceCimCheck -and $serviceCimCheck.State -eq 'Running') {
        Write-Host "  [✓] Windows Installer service started" -ForegroundColor Green
    }
    elseif ($serviceCimCheck -and $serviceCimCheck.State -eq 'Stopped') {
        Write-Host "  [i] Service is configured but stopped (will start on-demand)" -ForegroundColor Gray
    }
    else {
        Write-Host "  [!] Could not verify service state" -ForegroundColor Yellow
        Write-Host "  [i] Service will start automatically when needed" -ForegroundColor Gray
    }
}
else {
    Write-Host "`n[6] Skipping service restart (NoRestart flag)" -ForegroundColor Yellow
}

# Final status check
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Status Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check for remaining installer processes
$allMsiexec = Get-Process -Name "msiexec" -ErrorAction SilentlyContinue

if ($allMsiexec) {
    # Try to get command lines via WMI to distinguish service from installer instances
    $installerInstances = @()
    try {
        $wmiProcesses = Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue
        foreach ($proc in $wmiProcesses) {
            # Service instance has no command line args or just "/V"
            if ($proc.CommandLine -and $proc.CommandLine -notmatch "^.*msiexec\.exe[`"']?\s*(\/V)?\s*$") {
                $installerInstances += $proc
            }
        }
    }
    catch {
        # If WMI fails, assume multiple instances = problem
        if ($allMsiexec.Count -gt 1) {
            $installerInstances = $allMsiexec
        }
    }
    
    if ($installerInstances.Count -gt 0) {
        Write-Host "[!] Warning: $($installerInstances.Count) active installer instance(s) detected" -ForegroundColor Yellow
    }
    elseif ($allMsiexec.Count -eq 1) {
        Write-Host "[✓] Only service msiexec.exe running (normal)" -ForegroundColor Green
    }
    else {
        Write-Host "[✓] Multiple service instances running (normal after restart)" -ForegroundColor Green
    }
}
else {
    Write-Host "[✓] No installer processes running" -ForegroundColor Green
}

# Check Windows Installer service
try {
    $msiServiceFinal = Get-CimInstance -ClassName Win32_Service -Filter "Name='msiserver'" -ErrorAction Stop
    $pathValid = -not [string]::IsNullOrWhiteSpace($msiServiceFinal.PathName)
    $startModeValid = $msiServiceFinal.StartMode -ne 'Unknown'
    
    Write-Host "[i] Windows Installer service state: $($msiServiceFinal.State)" -ForegroundColor $(if ($msiServiceFinal.State -eq 'Stopped' -or $msiServiceFinal.State -eq 'Running') { 'Green' }else { 'Yellow' })
    Write-Host "[i] Service StartMode: $($msiServiceFinal.StartMode)" -ForegroundColor $(if ($startModeValid) { 'Green' }else { 'Yellow' })
    Write-Host "[i] Service PathName: $(if($pathValid){$msiServiceFinal.PathName}else{'[EMPTY - STILL CORRUPTED!]'})" -ForegroundColor $(if ($pathValid) { 'Green' }else { 'Red' })
}
catch {
    Write-Host "[!] Could not query Windows Installer service status" -ForegroundColor Red
}

# Check InProgress key
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress") {
    Write-Host "[!] Warning: InProgress key still exists" -ForegroundColor Yellow
}
else {
    Write-Host "[✓] InProgress key cleared" -ForegroundColor Green
}

# Display AFTER state
Show-ServiceRegistryConfig -Title "AFTER: Final Service Configuration"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "MSI Installation preparation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nYou can now proceed with your MSI installation.`n" -ForegroundColor White
