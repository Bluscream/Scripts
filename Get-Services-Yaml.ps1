# Ensure powershell-yaml module is installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'powershell-yaml module not found. Installing...'
    Install-Module powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
}

# Requires -Modules powershell-yaml

# Suppress all errors and warnings
$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# Check if running as administrator
function Test-IsAdmin {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

$IsAdmin = Test-IsAdmin

# Helper to get service details
function Get-ServiceDetails {
    param($Service)
    try {
        $wmi = Get-CimInstance -ClassName Win32_Service -Filter "Name = '$($Service.Name)'" -ErrorAction SilentlyContinue
        return $wmi
    } catch { return $null }
}

$services = Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
    $svc = $_
    if ($IsAdmin) {
        $details = Get-ServiceDetails $svc
        [PSCustomObject]@{
            Name        = $svc.Name
            DisplayName = $svc.DisplayName
            Status      = $svc.Status.ToString()
            StartType   = if ($details) { $details.StartMode } else { 'Unknown' }
            Path        = if ($details) { $details.PathName } else { $null }
            User        = if ($details) { $details.StartName } else { $null }
            Description = if ($details) { $details.Description } else { $null }
            ProcessId   = if ($details) { $details.ProcessId } else { $null }
        }
    } else {
        [PSCustomObject]@{
            Name        = $svc.Name
            DisplayName = $svc.DisplayName
            Status      = $svc.Status.ToString()
        }
    }
}

$services | ConvertTo-Yaml
