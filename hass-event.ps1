param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$Message
)

. "$PSScriptRoot/powershell/bluscream.ps1"

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
Set-ConsoleWindow -Action Hide

Send-HassEvent -Message $Message