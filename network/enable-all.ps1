# Get all disabled network adapters
$adapters = Get-NetAdapter # | Where-Object { $_.Status -eq "Disabled" }

$adapters | Format-Table Name, Status

$excludedAdapters = @("Bluetooth Network Connection", "vEthernet (Default Switch)")

# Enable each disabled adapter
foreach ($adapter in $adapters) {
    if ($excludedAdapters -contains $adapter.Name) {
        Write-Host "Excluding adapter: $($adapter.Name)"
        continue
    }
    Write-Host "Processing adapter: $($adapter.Name)"
    try {
        # Disable-NetAdapter -Name $adapter.Name -Confirm:$false
        Start-Sleep -Seconds 1  # Wait for adapter to initialize
        Enable-NetAdapter -Name $adapter.Name -Confirm:$false
    }
    catch {
        Write-Warning "Failed to enable adapter: $($adapter.Name)"
    }
}

# Display final status
Get-NetAdapter | Format-Table Name, Status

Read-Host