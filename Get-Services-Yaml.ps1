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

# Fetch all Win32_Service objects at once for performance
$allServiceDetails = @{}
if ($IsAdmin) {
    foreach ($wmi in Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue) {
        $allServiceDetails[$wmi.Name] = $wmi
    }
}

$services = Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
    $svc = $_
    if ($IsAdmin) {
        $details = $allServiceDetails[$svc.Name]
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
