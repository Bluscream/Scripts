# Ensure powershell-yaml module is installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'powershell-yaml module not found. Installing...'
    Install-Module powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
}

# Requires -Modules powershell-yaml

# Check if running as administrator
function Test-IsAdmin {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

$IsAdmin = Test-IsAdmin

# Helper to get process owner
function Get-ProcessOwner {
    param($ProcessId)
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
        $owner = $proc | Invoke-CimMethod -MethodName GetOwner
        if ($owner.User) { "$($owner.Domain)\\$($owner.User)" } else { $null }
    } catch { $null }
}

# Helper to get process working directory
function Get-ProcessWorkingDirectory {
    param($ProcessId)
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
        $proc.ExecutablePath | ForEach-Object {
            $file = Get-Item $_ -ErrorAction SilentlyContinue
            if ($file) { $file.DirectoryName } else { $null }
        }
    } catch { $null }
}

# Helper to get process elevation (per-process)
function Get-ProcessElevation {
    param($ProcessId)
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $hProcess = $proc.Handle
        if (-not $hProcess) { return "Unknown" }
        $definition = @"
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
        Add-Type -TypeDefinition $definition -ErrorAction SilentlyContinue
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
            $sig = 'bool IsWow64Process(IntPtr hProcess, [ref] bool Wow64Process)'
            $type = Add-Type -MemberDefinition "[DllImport(\"kernel32.dll\")] public static extern $sig;" -Name 'Kernel32' -Namespace 'Win32' -PassThru -ErrorAction SilentlyContinue
            $type::IsWow64Process($Process.Handle, [ref]$isWow64) | Out-Null
            if ($isWow64) { return "32-bit" } else { return "64-bit" }
        } else { return "32-bit" }
    } catch {
        # Fallback: try MainModule
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
    if ($IsAdmin) {
        $owner = Get-ProcessOwner $id
        $workdir = Get-ProcessWorkingDirectory $id
        $bitness = try { Get-ProcessBitness $proc } catch { "Unknown" }
        $cmdline = try { (Get-CimInstance Win32_Process -Filter "ProcessId = $id").CommandLine } catch { $null }
        $elevated = try { Get-ProcessElevation $id } catch { "Unknown" }
        [PSCustomObject]@{
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
    } else {
        [PSCustomObject]@{
            Name        = $proc.ProcessName
            Id          = $id
            MemoryMB    = [math]::Round($proc.WorkingSet / 1MB, 2)
        }
    }
}

$processes | ConvertTo-Yaml
