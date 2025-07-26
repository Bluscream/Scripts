# Service Discovery Parser
# Parses discovery.log and generates device JSON files

param(
    [string]$LogFile = "discovery.log",
    [string]$OutputDir = "devices",
    [switch]$Verbose
)

# Ensure output directory exists
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Function to parse notes information
function Parse-Notes {
    param([string]$Note)
    
    if ([string]::IsNullOrWhiteSpace($Note)) {
        return @()
    }
    
    # Split by comma and trim each part
    $notes = $Note.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    return $notes
}

# Function to create service object
function New-ServiceObject {
    param(
        [string]$Name,
        [int]$Port,
        [string]$Description = "",
        [string]$Image = "",
        [string[]]$Notes = @()
    )
    
    $service = @{
        port = $Port
        name = $Name
    }
    
    if ($Description) {
        $service.Description = $Description
    }
    
    if ($Image) {
        $service.Image = $Image
    }
    
    if ($Notes.Count -gt 0) {
        $service.notes = $Notes
    }
    
    return $service
}

# Function to determine service type and add appropriate image
function Get-ServiceImage {
    param([string]$ServiceName, [string]$Protocol, [int]$Port)
    
    $serviceName = $ServiceName.ToLower()
    
    # SSH
    if ($Port -eq 22 -or $serviceName -like "*ssh*") {
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/OpenSSH_logo.svg/1200px-OpenSSH_logo.svg.png"
    }
    
    # VNC
    if ($Port -eq 5900 -or $serviceName -like "*vnc*") {
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/VNC_logo.svg/1200px-VNC_logo.svg.png"
    }
    
    # RDP
    if ($Port -eq 3389 -or $serviceName -like "*rdp*" -or $serviceName -like "*terminal*") {
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/9/9a/Remote_Desktop_Protocol_logo.svg/1200px-Remote_Desktop_Protocol_logo.svg.png"
    }
    
    # HTTP/HTTPS
    if ($Protocol -eq "HTTP" -or $Protocol -eq "HTTPS") {
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Logo_TV_2015.svg/1200px-Logo_TV_2015.svg.png"
    }
    
    # Common services
    switch ($serviceName) {
        { $_ -like "*nginx*" } { return "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Nginx_logo.svg/1200px-Nginx_logo.svg.png" }
        { $_ -like "*mysql*" } { return "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0d/MySQL_logo.svg/1200px-MySQL_logo.svg.png" }
        { $_ -like "*redis*" } { return "https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Logo-redis.svg/1200px-Logo-redis.svg.png" }
        { $_ -like "*memcached*" } { return "https://upload.wikimedia.org/wikipedia/commons/thumb/5/53/Memcached_logo.svg/1200px-Memcached_logo.svg.png" }
        { $_ -like "*steam*" } { return "https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Steam_icon_logo.svg/1200px-Steam_icon_logo.svg.png" }
        { $_ -like "*discord*" } { return "https://upload.wikimedia.org/wikipedia/commons/thumb/9/98/Discord_logo.svg/1200px-Discord_logo.svg.png" }
    }
    
    return ""
}

# Function to add a service to an array only if no service with the same port exists
function Add-UniqueService {
    param(
        [ref]$array,
        $serviceObj
    )
    $exists = $array.Value | Where-Object { $_.port -eq $serviceObj.port }
    if (-not $exists) {
        $array.Value += $serviceObj
    }
}

# Read and parse the log file
$logContent = Get-Content $LogFile -Raw
$lines = $logContent -split "`n"

# Parse device information
$deviceInfo = $null
$services = @()
$inDeviceSection = $false
$inServiceSection = $false

foreach ($line in $lines) {
    $line = $line.Trim()
    
    # Skip empty lines
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    
    # Check for section headers
    if ($line.StartsWith("#")) {
        if ($line -like "*hostname;os;ipv4s;ipv6s;macs*") {
            $inDeviceSection = $true
            $inServiceSection = $false
            continue
        }
        elseif ($line -like "*hostname;service name;protocol;port;status;ping ms;source;note*") {
            $inDeviceSection = $false
            $inServiceSection = $true
            continue
        }

        continue
    }
    
    # Handle device info data in device section (non-commented lines)
    if ($inDeviceSection -and $line -match "^([^;]+);([^;]+);([^;]*);([^;]*);([^;]*)$") {
        $deviceInfo = @{
            name = $matches[1].Trim()
            os   = $matches[2].Trim()
            ipv4 = @()
            ipv6 = @()
            macs = @()
        }
        # Parse IPv4 addresses
        if ($matches[3] -and $matches[3] -ne "") {
            $deviceInfo.ipv4 = $matches[3].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        # Parse IPv6 addresses
        if ($matches[4] -and $matches[4] -ne "") {
            $deviceInfo.ipv6 = $matches[4].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        # Parse MAC addresses
        if ($matches[5] -and $matches[5] -ne "") {
            $deviceInfo.macs = $matches[5].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        continue
    }
    
    # Parse service lines (hostname;service name;protocol;port;status;ping ms;source;note)
    if ($inServiceSection -and $line -match "^([^;]+);([^;]+);([^;]+);([^;]+);([^;]+);([^;]*);([^;]*);(.*)$") {
        $hostname = $matches[1].Trim()
        $serviceName = $matches[2].Trim()
        $protocol = $matches[3].Trim()
        $port = [int]$matches[4].Trim()
        $status = $matches[5].Trim()
        $pingMs = $matches[6].Trim()
        $source = $matches[7].Trim()
        $note = $matches[8].Trim()
        
        # Only process successful services
        if ($status -eq "success") {
            $services += @{
                hostname = $hostname
                name     = $serviceName
                protocol = $protocol
                port     = $port
                pingMs   = $pingMs
                source   = $source
                note     = $note
            }
        }
    }
}

# Group services by device
$devices = @{}
foreach ($service in $services) {
    $hostname = $service.hostname
    if (!$devices.ContainsKey($hostname)) {
        $devices[$hostname] = @{
            ssh   = @()
            vnc   = @()
            rdp   = @()
            http  = @()
            https = @()
            tcp   = @()
            udp   = @()
        }
    }
    
    $device = $devices[$hostname]
    $port = $service.port
    $serviceName = $service.name
    $protocol = $service.protocol
    $note = $service.note
    
    # Parse notes information
    $notes = Parse-Notes -Note $note
    
    # Determine service type and add to appropriate array
    $serviceObj = New-ServiceObject -Name $serviceName -Port $port -Notes $notes
    $serviceObj.Image = Get-ServiceImage -ServiceName $serviceName -Protocol $protocol -Port $port

    switch ($protocol) {
        "SSH" { Add-UniqueService -array ([ref]$device.ssh)   $serviceObj }
        "VNC" { Add-UniqueService -array ([ref]$device.vnc)   $serviceObj }
        "RDP" { Add-UniqueService -array ([ref]$device.rdp)   $serviceObj }
        "HTTP" { Add-UniqueService -array ([ref]$device.http)  $serviceObj }
        "HTTPS" { Add-UniqueService -array ([ref]$device.https) $serviceObj }
        "TCP" {
            # Check for specific service types based on port or name
            if ($port -eq 22 -or $serviceName -like "*ssh*") {
                Add-UniqueService -array ([ref]$device.ssh) $serviceObj
            }
            elseif ($port -eq 5900 -or $serviceName -like "*vnc*") {
                Add-UniqueService -array ([ref]$device.vnc) $serviceObj
            }
            elseif ($port -eq 3389 -or $serviceName -like "*rdp*" -or $serviceName -like "*terminal*") {
                Add-UniqueService -array ([ref]$device.rdp) $serviceObj
            }
            else {
                Add-UniqueService -array ([ref]$device.tcp) $serviceObj
            }
        }
        "UDP" { Add-UniqueService -array ([ref]$device.udp)   $serviceObj }
    }
}

# Generate JSON files for each device
foreach ($hostname in $devices.Keys) {
    $deviceData = $devices[$hostname]
    
    # Get device info for this hostname
    $currentDeviceInfo = if ($deviceInfo -and $deviceInfo.name -eq $hostname) { $deviceInfo } else { @{ name = $hostname; os = "Unknown"; ipv4 = @(); ipv6 = @(); macs = @() } }
    
    # Create ordered hashtable with keys in specified order
    $deviceJson = [ordered]@{
        name  = $currentDeviceInfo.name
        os    = $currentDeviceInfo.os
        ipv4  = @() + $currentDeviceInfo.ipv4
        ipv6  = @() + $currentDeviceInfo.ipv6
        macs  = @() + $currentDeviceInfo.macs
        http  = @() + $deviceData.http
        https = @() + $deviceData.https
        ssh   = @() + $deviceData.ssh
        vnc   = @() + $deviceData.vnc
        rdp   = @() + $deviceData.rdp
        tcp   = @() + $deviceData.tcp
        udp   = @() + $deviceData.udp
    }
    
    # Convert to JSON with proper formatting
    $jsonContent = $deviceJson | ConvertTo-Json -Depth 10 -Compress:$false
    
    # Write to file
    $outputFile = Join-Path $OutputDir "$hostname.json"
    $jsonContent | Out-File -FilePath $outputFile -Encoding UTF8
    
    if ($Verbose) {
        Write-Host "Generated device file: $outputFile"
        Write-Host "  - SSH services: $($deviceData.ssh.Count)"
        Write-Host "  - VNC services: $($deviceData.vnc.Count)"
        Write-Host "  - RDP services: $($deviceData.rdp.Count)"
        Write-Host "  - HTTP services: $($deviceData.http.Count)"
        Write-Host "  - HTTPS services: $($deviceData.https.Count)"
        Write-Host "  - TCP services: $($deviceData.tcp.Count)"
        Write-Host "  - UDP services: $($deviceData.udp.Count)"
    }
}

Write-Host "Parsing complete! Generated $($devices.Count) device file(s) in '$OutputDir' directory."
