# Ensure powershell-yaml module is installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'powershell-yaml module not found. Installing...'
    Install-Module powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
}

# Requires -Modules powershell-yaml

# Pre-fetch all Win32_Process objects and index by PID
$wmiProcs = Get-CimInstance Win32_Process
$wmiProcById = @{}
foreach ($w in $wmiProcs) { $wmiProcById[$w.ProcessId] = $w }

# Compile .NET types once for elevation and bitness
$elevationDefinition = @"
using System;
using System.Runtime.InteropServices;
public class TokenInfo {
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, UInt32 DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, ref int TokenInformation, int TokenInformationLength, out int ReturnLength);
    public const int TokenElevation = 20;
    public const UInt32 TOKEN_QUERY = 0x0008;
}
"@
Add-Type -TypeDefinition $elevationDefinition -ErrorAction SilentlyContinue

$bitnessDefinition = @"
using System;
using System.Runtime.InteropServices;
public class Kernel32 {
    [DllImport("kernel32.dll")]
    public static extern bool IsWow64Process(IntPtr hProcess, ref bool Wow64Process);
}
"@
Add-Type -TypeDefinition $bitnessDefinition -ErrorAction SilentlyContinue

# Check if running as administrator
function Test-IsAdmin {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

$IsAdmin = Test-IsAdmin

# Helper to get process owner (from pre-fetched WMI)
function Get-ProcessOwner {
    param($WmiProc)
    try {
        $owner = $WmiProc | Invoke-CimMethod -MethodName GetOwner
        if ($owner.User) { "$($owner.Domain)\$($owner.User)" } else { $null }
    } catch { $null }
}

# Helper to get process working directory (from pre-fetched WMI)
function Get-ProcessWorkingDirectory {
    param($WmiProc)
    try {
        $WmiProc.ExecutablePath | ForEach-Object {
            $file = Get-Item $_ -ErrorAction SilentlyContinue
            if ($file) { $file.DirectoryName } else { $null }
        }
    } catch { $null }
}

# Helper to get process elevation (per-process)
function Get-ProcessElevation {
    param($Process)
    try {
        $hProcess = $Process.Handle
        if (-not $hProcess) { return "Unknown" }
        $tokenHandle = [IntPtr]::Zero
        $opened = [TokenInfo]::OpenProcessToken($hProcess, [TokenInfo]::TOKEN_QUERY, [ref]$tokenHandle)
        if (-not $opened) { return "Unknown" }
        $elev = 0
        $outLen = 0
        $success = [TokenInfo]::GetTokenInformation($tokenHandle, [TokenInfo]::TokenElevation, [ref]$elev, [System.Runtime.InteropServices.Marshal]::SizeOf([int]), [ref]$outLen)
        if ($success) { return ([bool]$elev).ToString() } else { return "Unknown" }
    } catch { return "Unknown" }
}

# Helper to get process bitness
function Get-ProcessBitness {
    param($Process)
    try {
        if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
            $isWow64 = $false
            [Kernel32]::IsWow64Process($Process.Handle, [ref]$isWow64) | Out-Null
            if ($isWow64) { return "32-bit" } else { return "64-bit" }
        } else { return "32-bit" }
    } catch {
        try {
            if ($Process.MainModule.ModuleName -match "(SysWOW64|WOW64)") { return "32-bit" }
            else { return "64-bit" }
        } catch { return "Unknown" }
    }
}

# Main process collection
$processes = Get-Process | ForEach-Object {
    $proc = $_
    $id = $proc.Id
    $wmi = $wmiProcById[$id]
    $missingWmi = $false
    if ($IsAdmin) {
        if ($wmi) {
            $owner = Get-ProcessOwner $wmi
            $workdir = Get-ProcessWorkingDirectory $wmi
            $cmdline = $wmi.CommandLine
        } else {
            $missingWmi = $true
            # Fallbacks (slower)
            $owner = try {
                Get-CimInstance Win32_Process -Filter "ProcessId = $id" | Invoke-CimMethod -MethodName GetOwner | ForEach-Object { if ($_.User) { "$($_.Domain)\$($_.User)" } else { $null } }
            } catch { $null }
            $workdir = $null
            $cmdline = try {
                (Get-CimInstance Win32_Process -Filter "ProcessId = $id").CommandLine
            } catch { $null }
        }
        $bitness = try { Get-ProcessBitness $proc } catch { "Unknown" }
        $elevated = try { Get-ProcessElevation $proc } catch { "Unknown" }
        $yamlObj = [PSCustomObject]@{
            Name        = $proc.ProcessName
            Id          = $id
            Path        = $proc.Path
            CommandLine = $cmdline
            WorkingDir  = $workdir
            Elevated    = $elevated
            Bitness     = $bitness
            User        = $owner
            StartTime   = $proc.StartTime
            CPU         = $proc.CPU
            MemoryMB    = [math]::Round($proc.WorkingSet / 1MB, 2)
        }
        if ($missingWmi) {
            # Add a comment property to indicate missing WMI data
            # Add-Member -InputObject $yamlObj -NotePropertyName "_comment" -NotePropertyValue "WMI data missing, used fallback methods. Some fields may be incomplete."
        }
        $yamlObj
    } else {
        [PSCustomObject]@{
            Name        = $proc.ProcessName
            Id          = $id
            MemoryMB    = [math]::Round($proc.WorkingSet / 1MB, 2)
        }
    }
}

$processes | ConvertTo-Yaml
