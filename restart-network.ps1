# Define the names of the WiFi adapters based on the output of ipconfig /all
$wifi5GhzAdapterName = "Wi-Fi (5Ghz)"
$wifi24GhzAdapterName = "Wi-Fi (2.4Ghz)"

# Function to disable and enable all network adapters
function Restart-NetworkAdapters {
    # Get all network adapters
    $adapters = Get-NetAdapter

    # Disable all adapters
    foreach ($adapter in $adapters) {
        Write-Host "Disabling Network Adapter $($adapter.Name)"
        Disable-NetAdapter -Name $adapter.Name -Confirm:$false
    }

    # Enable all adapters
    foreach ($adapter in $adapters) {
        Write-Host "Enabling Network Adapter $($adapter.Name)"
        Enable-NetAdapter -Name $adapter.Name -Confirm:$false
    }
}

# Function to connect a specific WiFi adapter to a specific network
function Connect-WiFiAdapterToNetwork {
    param(
        [string]$adapterName,
        [string]$networkName
    )

    # Connect the specified adapter to the specified network
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $adapterName }
    if ($adapter) {
        $network = Get-NetWLANProfile | Where-Object { $_.Name -eq $networkName }
        if ($network) {
            Set-NetConnectionProfile -InterfaceIndex $adapter.InterfaceIndex -NetworkCategory Private
            netsh wlan connect name=$networkName
        }
        else {
            Write-Host "Network $networkName not found."
        }
    }
    else {
        Write-Host "Adapter $adapterName not found."
    }
}

Format-Table -InputObject (Get-NetIPConfiguration) -Property @{Label = "Status"; Expression = { $_.NetAdapter.Status } }, InterfaceAlias, InterfaceDescription, IPv4DefaultGateway -AutoSize

# Restart all network adapters
Restart-NetworkAdapters

# Connect the 5GHz WiFi adapter to LH5
Connect-WiFiAdapterToNetwork -adapterName $wifi5GhzAdapterName -networkName "LH5"

# Connect the 2.4GHz WiFi adapter to LH
Connect-WiFiAdapterToNetwork -adapterName $wifi24GhzAdapterName -networkName "LH"

Format-Table -InputObject (Get-NetIPConfiguration) -Property @{Label = "Status"; Expression = { $_.NetAdapter.Status } }, InterfaceAlias, InterfaceDescription, IPv4DefaultGateway -AutoSize