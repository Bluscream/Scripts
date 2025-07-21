# powershell/bluscream.ps1
# Common helper functions for Bluscream scripts

# region Elevation
function Is-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Elevate-Self {
    if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
            $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
            Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine
            Exit
        }
    }
}
# endregion Elevation

# region Console UI
function Set-Title {
    param (
        [string]$message,
        [string]$color = 'Green'
    )
    $Host.UI.RawUI.WindowTitle = $message
    Write-Host $message -ForegroundColor $color
}

function Pause ($message) {
    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message)
    }
    else {
        Write-Host $message -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

enum WindowAction {
    Minimize
    Hide
    Maximize
}
function Set-ConsoleWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [WindowAction]$Action
    )

    # Get the current process main window handle
    $hwnd = (Get-Process -Id $PID).MainWindowHandle

    if (-not $hwnd -or $hwnd -eq 0) {
        Write-Host "[Set-ConsoleWindow] No main window handle found for this process!" -ForegroundColor DarkYellow
        return
    }

    # Define Win32 API functions
    $signature = @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

    Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue

    # Map enum to ShowWindow command
    switch ($Action) {
        'Minimize' { $cmd = 6 } # SW_MINIMIZE
        'Hide'     { $cmd = 0 } # SW_HIDE
        'Maximize' { $cmd = 3 } # SW_MAXIMIZE
        default    { $cmd = 5 } # SW_SHOW
    }

    [Win32]::ShowWindow($hwnd, $cmd) | Out-Null
}
# endregion Console UI

# region String Helpers
function Quote {
    process {
        Write-Output "`"$_`""
    }
}
# endregion String Helpers

# region File System
function Clear-Directory {
    param (
        [string]$Path,
        [switch]$RemoveDir
    )

    $pathStr = $Path | Quote

    if (-not (Test-Path $Path)) {
        Write-Host "$pathStr does not exist" -ForegroundColor DarkGray
        return
    }
    if ($RemoveDir) {
        $removeStr = 'Remov'
        $removePath = $Path
    } else {
        $removeStr = 'Clean'
        $removePath = "$Path\*"
    }
    Set-Title "$($removeStr)ing directory $pathStr"
    try {
        Remove-Item -Path $removePath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "$($removeStr)ed directory $pathStr"
    }
    catch {
        if ($_.Exception.Message -like "*because it is being used by another process*") {
            Write-Host $($_.Exception.Message) -ForegroundColor Yellow
        } else {
            Write-Host "Error $($removeStr)ing directory $pathStr - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
# endregion File System

# region System Actions
function Show-Toast {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Title = "PowerShell"
    )
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text $Title, $Message
        } else {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            $textNodes = $template.GetElementsByTagName("text")
            $textNodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
            $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
            $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell")
            $notifier.Show($toast)
        }
    } catch {
        Write-Host "[SPECIAL] Toast notification (no compatible method found)" -ForegroundColor Magenta
    }
}

function Logout-CurrentUser {
    try {
        shutdown.exe /l
    } catch {
        Write-Host "[SPECIAL] Failed to log out: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Sleep-Computer {
    try {
        rundll32.exe powrprof.dll,SetSuspendState 0,1,0
    } catch {
        Write-Host "[SPECIAL] Failed to sleep: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Lock-Computer {
    try {
        rundll32.exe user32.dll,LockWorkStation
    } catch {
        Write-Host "[SPECIAL] Failed to lock: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Hibernate-Computer {
    try {
        rundll32.exe powrprof.dll,SetSuspendState Hibernate
    } catch {
        Write-Host "[SPECIAL] Failed to hibernate: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-PowerProfile {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("powersaver","balanced","highperformance")][string]$Profile
    )
    $guids = @{
        powersaver = "a1841308-3541-4fab-bc81-f71556f20b4a"
        balanced = "381b4222-f694-41f0-9685-ff5bb260df2e"
        highperformance = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    }
    if ($guids.ContainsKey($Profile)) {
        try {
            powercfg.exe /s $guids[$Profile]
            Write-Host "Power plan set to $Profile"
        } catch {
            Write-Host "[SPECIAL] Failed to set $Profile power plan $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "Unknown power profile: $Profile" -ForegroundColor Red
    }
}
# endregion System Actions

# Only export module members if running as a module (not dot-sourced as a script)
if ($MyInvocation.ScriptName -and ($MyInvocation.ScriptName -like '*.psm1')) {
    Export-ModuleMember -Function Elevate-Self,Set-Title,Pause,Quote,Clear-Directory,Show-Toast,Logout-CurrentUser,Sleep-Computer,Lock-Computer,Hibernate-Computer,Set-PowerProfile
} 