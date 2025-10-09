function Show-NetworkAdapterStatus {
    param(
        [string]$Title = "Network Adapter Status"
    )
    
    Write-Host "`n$Title" -ForegroundColor Cyan
    Write-Host ("=" * $Title.Length) -ForegroundColor Cyan
    
    $adapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike '*Loopback*' }
    $results = @()
    
    foreach ($adapter in $adapters) {
        $ipv4Interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        
        $ipv4Address = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
            Where-Object { $_.IPAddress -notlike '169.254.*' } | 
            Select-Object -First 1).IPAddress
        
        $ipv6Address = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | 
            Where-Object { $_.IPAddress -notlike 'fe80:*' } | 
            Select-Object -First 1).IPAddress
        
        $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | 
            Where-Object { $_.ServerAddresses.Count -gt 0 }).ServerAddresses -join ', '
        
        $gateway = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop
        
        # Get IPv6 binding status
        $ipv6Binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        $ipv6Status = if ($ipv6Binding.Enabled) { "Enabled" } else { "Disabled" }
        
        $results += [PSCustomObject]@{
            'Alias'       = $adapter.Name
            'Description' = $adapter.InterfaceDescription
            'Status'      = $adapter.Status
            'IPv4'        = if ($ipv4Address) { $ipv4Address } else { "-" }
            'IPv4-DHCP'   = if ($ipv4Interface) { if ($ipv4Interface.Dhcp -eq 'Enabled') { "Yes" } else { "No" } } else { "-" }
            'IPv6'        = if ($ipv6Address) { $ipv6Address } else { "-" }
            'IPv6-Status' = $ipv6Status
            'Gateway'     = if ($gateway) { $gateway } else { "-" }
            'DNS'         = if ($dnsServers) { ($dnsServers -split ', ' | Select-Object -First 3) -join ', ' } else { "-" }
        }
    }
    
    $results | Format-Table -AutoSize -Wrap
    Write-Host ""
}

class NetworkAdapterSettings {
    [string]$Name
    [string]$Alias
    [bool]$Enabled = $true
    [string[]]$DNSServers = @('127.0.0.1', '::1')
    [string]$SubnetMask = '255.255.255.0'
    [string]$Gateway = '192.168.2.1'
    [string]$Ipv4
    [string]$Ipv6
    [int]$Ipv6PrefixLength = 64
    [string]$SSID
    
    NetworkAdapterSettings([string]$name) { $this.Name = $name }
}

$adapters = @()

$adapter = [NetworkAdapterSettings]::new('802.11n USB Wireless LAN Card')
$adapter.Alias = 'Wi-Fi (5Ghz)'
$adapter.Ipv4 = '192.168.2.52'
# $adapter.Ipv6 = 'fe80::1'
$adapter.SSID = "LH"
$adapters += $adapter

$adapter = [NetworkAdapterSettings]::new('Realtek PCIe 2.5GbE Family Controller')
$adapter.Alias = 'Ethernet 2.5G'
$adapter.Ipv4 = '192.168.2.50'
# $adapter.Ipv6 = 'fe80::1'
$adapters += $adapter

$adapter = [NetworkAdapterSettings]::new('Intel(R) Ethernet Connection (11) I219-V')
$adapter.Alias = 'Ethernet 1G'
$adapter.Ipv4 = '192.168.2.51'
# $adapter.Ipv6 = 'fe80::1'
$adapters += $adapter

$adapter = [NetworkAdapterSettings]::new('Xbox Wireless Adapter for Windows')
# $adapter.Alias = 'Xbox Wireless Adapter'
$adapter.Enabled = $false
$adapters += $adapter

$adapter = [NetworkAdapterSettings]::new('Bluetooth Device (Personal Area Network)')
# $adapter.Alias = 'Bluetooth Network Connection'
$adapter.Enabled = $false
$adapters += $adapter

$adapter = [NetworkAdapterSettings]::new('Hyper-V Virtual Ethernet Adapter')
$adapter.Enabled = $false
$adapters += $adapter

$adapter = [NetworkAdapterSettings]::new('Tailscale Tunnel')
$adapter.Ipv4 = '100.100.1.50'
$adapter.Ipv6 = 'fd7a:115c:a1e0::af01:1582'
$adapter.Ipv6PrefixLength = 128
$adapter.Gateway = '100.100.1.1'
$adapter.SubnetMask = '255.192.0.0'
# $adapter.DNSServers = @('100.100.100.100', 'fd7a:115c:a1e0::53')
# $adapters += $adapter

# Show current network adapter status
Show-NetworkAdapterStatus -Title "Current Network Configuration"

Write-Host "$($adapters.Count) network adapters configured" -ForegroundColor Cyan
$adapters | Format-Table -AutoSize

foreach ($adapter in $adapters) {
    Write-Host "`nConfiguring: " -NoNewline
    Write-Host "$($adapter.Name)" -ForegroundColor Cyan
    
    # Try to find by InterfaceDescription first, then by Name
    $netAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { 
        $_.InterfaceDescription -eq $adapter.Name -or $_.Name -eq $adapter.Name -or $_.InterfaceDescription -like "*$($adapter.Name)*"
    } | Select-Object -First 1
    
    if (-not $netAdapter) {
        Write-Host "  ✗ Adapter not found (tried: '$($adapter.Name)')" -ForegroundColor Red
        continue
    }
    
    if ($netAdapter.InterfaceDescription -ne $adapter.Name -and $netAdapter.Name -ne $adapter.Name) {
        Write-Host "  ℹ Matched by partial name: $($netAdapter.InterfaceDescription)" -ForegroundColor DarkGray
    }
    
    # Enable or Disable the adapter
    if ($adapter.Enabled) {
        if ($netAdapter.Status -ne 'Up') {
            Enable-NetAdapter -InterfaceDescription $adapter.Name -Confirm:$false
            Write-Host "  ✓ Enabled" -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        
        # Rename adapter if alias is specified
        if ($adapter.Alias -and $netAdapter.Name -ne $adapter.Alias) {
            Rename-NetAdapter -Name $netAdapter.Name -NewName $adapter.Alias
            Write-Host "  ✓ Renamed to: $($adapter.Alias)" -ForegroundColor Green
            $netAdapter = Get-NetAdapter -Name $adapter.Alias
        }
        
        # Configure IP settings
        $useStaticIp = ($adapter.Ipv4 -or $adapter.Ipv6)
        
        if ($useStaticIp) {
            Write-Host "  → Configuring static IP..." -ForegroundColor Gray
            
            # Remove existing IPv4 configurations (except link-local)
            Get-NetIPAddress -InterfaceAlias $netAdapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
            Where-Object { $_.IPAddress -notlike '169.254.*' } | 
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            
            # Remove existing default gateway
            Get-NetRoute -InterfaceAlias $netAdapter.Name -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | 
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        }
        
        # Set IPv4 address with gateway
        if ($adapter.Ipv4) {
            try {
                # Set the IP address first without gateway
                New-NetIPAddress -InterfaceAlias $netAdapter.Name -IPAddress $adapter.Ipv4 -PrefixLength 24 -ErrorAction Stop | Out-Null
                Write-Host "  ✓ IPv4: $($adapter.Ipv4)" -ForegroundColor Green
                
                # Then try to add the gateway if specified
                if ($adapter.Gateway) {
                    New-NetRoute -InterfaceAlias $netAdapter.Name -DestinationPrefix '0.0.0.0/0' -NextHop $adapter.Gateway -ErrorAction Stop | Out-Null
                    Write-Host "  ✓ Gateway: $($adapter.Gateway)" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "  ✗ Failed to set IPv4: $_" -ForegroundColor Red
            }
        }
        
        # Set or disable IPv6
        if ($adapter.Ipv6) {
            # Remove existing IPv6 configurations (except link-local)
            Get-NetIPAddress -InterfaceAlias $netAdapter.Name -AddressFamily IPv6 -ErrorAction SilentlyContinue | 
            Where-Object { $_.IPAddress -notlike 'fe80:*' } | 
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            
            New-NetIPAddress -InterfaceAlias $netAdapter.Name -IPAddress $adapter.Ipv6 -PrefixLength 64 -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  ✓ IPv6: $($adapter.Ipv6)" -ForegroundColor Green
            # Enable IPv6 on the adapter
            Enable-NetAdapterBinding -Name $netAdapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        }
        else {
            # Disable IPv6 on the adapter
            Disable-NetAdapterBinding -Name $netAdapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
            Write-Host "  ✓ IPv6: Disabled" -ForegroundColor Yellow
        }
        
        # Set DNS servers
        if ($adapter.DNSServers -and $adapter.DNSServers.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceAlias $netAdapter.Name -ServerAddresses $adapter.DNSServers
            Write-Host "  ✓ DNS: $($adapter.DNSServers -join ', ')" -ForegroundColor Green
        }
        
        # Set DHCP based on whether static IPs are configured
        $dhcpSetting = if ($useStaticIp) { "Disabled" } else { "Enabled" }
        Set-NetIPInterface -InterfaceAlias $netAdapter.Name -Dhcp $dhcpSetting -ErrorAction SilentlyContinue
        if (-not $useStaticIp) {
            Write-Host "  ✓ DHCP Enabled" -ForegroundColor Green
        }
        
        # Configure WiFi SSID if specified
        if ($adapter.SSID) {
            try {
                netsh wlan connect name="$($adapter.SSID)" interface="$($netAdapter.Name)" | Out-Null
                Write-Host "  ✓ Connected to SSID: $($adapter.SSID)" -ForegroundColor Green
            }
            catch {
                Write-Host "  ✗ Failed to connect to SSID: $($adapter.SSID)" -ForegroundColor Yellow
            }
        }
        
    }
    else {
        if ($netAdapter.Status -ne 'Disabled') {
            Disable-NetAdapter -Name $netAdapter.Name -Confirm:$false
            Write-Host "  ✓ Disabled" -ForegroundColor Yellow
        }
        else {
            Write-Host "  - Already disabled" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n✓ Network configuration complete!" -ForegroundColor Green

# Show updated network adapter status
Show-NetworkAdapterStatus -Title "Updated Network Configuration"