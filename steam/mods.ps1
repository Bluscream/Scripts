# Helper function to convert parameters to URL query string
function ConvertTo-Query {
    param(
        [hashtable]$Parameters
    )
    
    $pairs = @()
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        $pairs += "{0}={1}" -f [System.Web.HttpUtility]::UrlEncode($key),
                             [System.Web.HttpUtility]::UrlEncode($value)
    }
    
    return $pairs -join '&'
}

# Main export function
function Export-SteamMods {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GameId,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    # Create directory if it doesn't exist
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
    }

    try {
        # Fetch subscribed mods using correct Steam API endpoint
        $apiUrl = "http://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileSubscriptions/v1/"
        $params = @{
            format = 'json'
        }

        # First request to get subscription count
        $response = Invoke-WebRequest -Uri ($apiUrl + '?' + (ConvertTo-Query $params))
        $data = $response.Content | ConvertFrom-Json
        
        # Initialize mod collection
        $gameMods = @()
        
        # Process mods in batches of 50 (API limit)
        $count = $data.response.total_items
        $batchSize = 50
        for ($i = 0; $i -lt $count; $i += $batchSize) {
            $params['start'] = $i
            $params['count'] = $batchSize
            
            $response = Invoke-WebRequest -Uri ($apiUrl + '?' + (ConvertTo-Query $params))
            $data = $response.Content | ConvertFrom-Json
            
            foreach ($mod in $data.response.publishedfiledetails) {
                if ($mod.consumer_app_id -eq $GameId) {
                    $gameMods += @{
                        mod_id = $mod.publishedfileid
                        name = $mod.title
                        description = $mod.description
                        time_created = $mod.time_created
                        visibility = $mod.visibility
                    }
                }
            }
        }

        # Export to JSON
        $gameMods | ConvertTo-Json | Set-Content -Path $OutputPath -Encoding UTF8
        
        Write-Host "Successfully exported $(@($gameMods).Count) mods for game $GameId to $OutputPath"
    }
    catch {
        Write-Error "Failed to export mods: $_"
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Error "HTTP Status Code: $statusCode"
        }
    }
}

# Example usage:
Export-SteamMods -GameId "4000" -OutputPath ".\mods\gmod.json"