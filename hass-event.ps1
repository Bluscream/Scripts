param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$Message
)

function Send-HassEvent {
    param(
        [Parameter(Position=0, Mandatory=$false)]
        [object]$EventData,
        [Parameter(Mandatory=$false)]
        [string]$Message
    )
    $homeAssistantUrl = $env:HASS_SERVER
    $accessToken = $env:HASS_TOKEN
    $endpoint = "${homeAssistantUrl}api/events/blu-pc"

    $eventData = @{
        now  = (Get-Date).ToString("o")
        pc   = $env:COMPUTERNAME
        user = $env:USERNAME
        message = $Message
    }
    if ($EventData -is [hashtable] -or $EventData -is [pscustomobject]) {
        foreach ($prop in $EventData.PSObject.Properties) {
            # Only copy NoteProperty (user data), not methods or .NET properties
            if ($prop.MemberType -eq 'NoteProperty') {
                $eventData[$prop.Name] = $prop.Value
            }
        }
    } else {
        Write-Error "EventData must be a string or an object with properties."
        exit 1
    }
    $jsonBody = $eventData | ConvertTo-Json -Depth 10
    Write-Host $jsonBody
    try {
        $response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers @{
            "Content-Type"  = "application/json"
            "Accept"        = "application/json"
            "Authorization" = "Bearer $accessToken"
        } -Body $jsonBody
        Write-Host "Event sent to Home Assistant"
    } catch {
        Write-Error "Error sending HomeAssistant event: $_"
        throw
    }
}
enum WindowAction {
    Minimize
    Hide
    Maximize
}
function Show-Window {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [WindowAction]$Action
    )

    # Get the current process main window handle
    $hwnd = (Get-Process -Id $PID).MainWindowHandle

    if (-not $hwnd -or $hwnd -eq 0) {
        Write-Error "No main window handle found for this process."
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

Show-Window -Action Hide

Send-HassEvent -Message $Message