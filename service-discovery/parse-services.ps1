# Service Discovery Parser
# Parses discovery.log and generates device JSON files

param(
    [string]$LogFile = "D:\Scripts\service-discovery\discovery.log",
    [string]$OutputFile = "service-discovery/devices/dev.json",
    [switch]$Verbose
)

# Function to parse notes information
function Parse-Notes {
    param([string]$Note)
    
    if ([string]::IsNullOrWhiteSpace($Note)) {
        Write-Verbose "No notes to parse." -Verbose:$Verbose
        return @()
    }
    
    # Split by comma and trim each part
    $notes = $Note.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Write-Verbose "Parsed notes: $($notes -join ', ')" -Verbose:$Verbose
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
    
    Write-Verbose "Created service object: Name=$Name, Port=$Port, Description=$Description, Image=$Image, Notes=$($Notes -join ', ')" -Verbose:$Verbose
    return $service
}

# Function to determine service type and add appropriate image
function Get-ServiceImage {
    param([string]$ServiceName, [string]$Protocol, [int]$Port)
    
    $serviceName = $ServiceName.ToLower()
    
    # SSH
    if ($Port -eq 22 -or $serviceName -like "*ssh*") {
        Write-Verbose "Matched SSH for $ServiceName on port $Port" -Verbose:$Verbose
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/OpenSSH_logo.svg/1200px-OpenSSH_logo.svg.png"
    }
    
    # SFTP (uses SSH port 22)
    if ($Port -eq 22 -or $serviceName -like "*sftp*") {
        Write-Verbose "Matched SFTP for $ServiceName on port $Port" -Verbose:$Verbose
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/OpenSSH_logo.svg/1200px-OpenSSH_logo.svg.png"
    }
    
    # FTP
    if ($Port -eq 21 -or $serviceName -like "*ftp*") {
        Write-Verbose "Matched FTP for $ServiceName on port $Port" -Verbose:$Verbose
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/2/24/FTP_logo.svg/1200px-FTP_logo.svg.png"
    }
    
    # VNC
    if ($Port -eq 5900 -or $serviceName -like "*vnc*") {
        Write-Verbose "Matched VNC for $ServiceName on port $Port" -Verbose:$Verbose
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/VNC_logo.svg/1200px-VNC_logo.svg.png"
    }
    
    # RDP
    if ($Port -eq 3389 -or $serviceName -like "*rdp*" -or $serviceName -like "*terminal*") {
        Write-Verbose "Matched RDP for $ServiceName on port $Port" -Verbose:$Verbose
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/9/9a/Remote_Desktop_Protocol_logo.svg/1200px-Remote_Desktop_Protocol_logo.svg.png"
    }
    
    # HTTP/HTTPS
    if ($Protocol -eq "HTTP" -or $Protocol -eq "HTTPS") {
        Write-Verbose "Matched HTTP/HTTPS for $ServiceName with protocol $Protocol" -Verbose:$Verbose
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Logo_TV_2015.svg/1200px-Logo_TV_2015.svg.png"
    }
    
    # Common services
    switch ($serviceName) {
        { $_ -like "*nginx*" } { Write-Verbose "Matched nginx for $ServiceName" -Verbose:$Verbose; return "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Nginx_logo.svg/1200px-Nginx_logo.svg.png" }
        { $_ -like "*mysql*" } { Write-Verbose "Matched mysql for $ServiceName" -Verbose:$Verbose; return "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0d/MySQL_logo.svg/1200px-MySQL_logo.svg.png" }
        { $_ -like "*redis*" } { Write-Verbose "Matched redis for $ServiceName" -Verbose:$Verbose; return "https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Logo-redis.svg/1200px-Logo-redis.svg.png" }
        { $_ -like "*memcached*" } { Write-Verbose "Matched memcached for $ServiceName" -Verbose:$Verbose; return "https://upload.wikimedia.org/wikipedia/commons/thumb/5/53/Memcached_logo.svg/1200px-Memcached_logo.svg.png" }
        { $_ -like "*steam*" } { Write-Verbose "Matched steam for $ServiceName" -Verbose:$Verbose; return "https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Steam_icon_logo.svg/1200px-Steam_icon_logo.svg.png" }
        { $_ -like "*discord*" } { Write-Verbose "Matched discord for $ServiceName" -Verbose:$Verbose; return "https://upload.wikimedia.org/wikipedia/commons/thumb/9/98/Discord_logo.svg/1200px-Discord_logo.svg.png" }
    }
    
    Write-Verbose "No image matched for $ServiceName (protocol $Protocol, port $Port)" -Verbose:$Verbose
    return ""
}

# Read and parse the log file
Write-Verbose "Reading log file: $LogFile" -Verbose:$Verbose
$logContent = Get-Content $LogFile -Raw
$lines = $logContent -split "`n"

# Parse timestamp from "# Generated at" line
$lastUpdated = $null
foreach ($line in $lines) {
    if ($line -match "^# Generated at (.+)$") {
        $lastUpdated = $matches[1].Trim()
        Write-Verbose "Found last updated timestamp: $lastUpdated" -Verbose:$Verbose
        break
    }
}

# Parse device information
$deviceInfos = @{}
$services = @()
$inDeviceSection = $false
$inServiceSection = $false
$firstDeviceFound = $false
$firstDeviceHostname = $null

foreach ($line in $lines) {
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.StartsWith("#")) {
        if ($line -like "*hostname;os;ipv4s;ipv6s;macs*") {
            Write-Verbose "Entering device section in log." -Verbose:$Verbose
            $inDeviceSection = $true
            $inServiceSection = $false
            continue
        }
        elseif ($line -like "*hostname;service name;protocol;port;status;ping ms;source;note*") {
            Write-Verbose "Entering service section in log." -Verbose:$Verbose
            $inDeviceSection = $false
            $inServiceSection = $true
            continue
        }
        continue
    }
    # Device info
    if ($inDeviceSection -and !$firstDeviceFound -and $line -match "^([^;]+);([^;]+);([^;]*);([^;]*);([^;]*)$") {
        $hostname = $matches[1].Trim()
        $firstDeviceHostname = $hostname
        $deviceInfos[$hostname] = @{
            name = $hostname
            os   = $matches[2].Trim()
            ipv4 = @()
            ipv6 = @()
            macs = @()
        }
        if ($matches[3] -and $matches[3] -ne "") {
            $deviceInfos[$hostname].ipv4 = $matches[3].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        if ($matches[4] -and $matches[4] -ne "") {
            $deviceInfos[$hostname].ipv6 = $matches[4].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        if ($matches[5] -and $matches[5] -ne "") {
            $deviceInfos[$hostname].macs = $matches[5].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        Write-Verbose "Parsed device info for $($hostname): OS=$($deviceInfos[$hostname].os), IPv4=$($deviceInfos[$hostname].ipv4 -join ', '), IPv6=$($deviceInfos[$hostname].ipv6 -join ', '), MACs=$($deviceInfos[$hostname].macs -join ', ')" -Verbose:$Verbose
        $firstDeviceFound = $true
        continue
    }
    # Service info (only for the first device)
    if ($inServiceSection -and $firstDeviceFound -and $firstDeviceHostname -and $line -match "^([^;]+);([^;]+);([^;]+);([^;]+);([^;]+);([^;]*);([^;]*);(.*)$") {
        $hostname = $matches[1].Trim()
        if ($hostname -ne $firstDeviceHostname) { continue }
        $serviceName = $matches[2].Trim()
        $protocol = $matches[3].Trim()
        $port = [int]$matches[4].Trim()
        $status = $matches[5].Trim()
        $pingMs = $matches[6].Trim()
        $source = $matches[7].Trim()
        $note = $matches[8].Trim()
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
            Write-Verbose "Parsed service: Host=$hostname, Name=$serviceName, Protocol=$protocol, Port=$port, Status=$status, PingMs=$pingMs, Source=$source, Note=$note" -Verbose:$Verbose
        }
    }
    # Stop parsing after first device and its services
    if ($inServiceSection -and $firstDeviceFound -and $firstDeviceHostname -and $line -notmatch "^([^;]+);([^;]+);([^;]+);([^;]+);([^;]+);([^;]*);([^;]*);(.*)$") {
        break
    }
}

# Group services by device (only one device)
$devices = @{}
if ($firstDeviceHostname) {
    $devices[$firstDeviceHostname] = @{
        ssh   = @()
        sftp  = @()
        ftp   = @()
        vnc   = @()
        rdp   = @()
        http  = @()
        https = @()
        tcp   = @()
        udp   = @()
    }
}
foreach ($service in $services) {
    $hostname = $service.hostname
    $device = $devices[$hostname]
    $port = $service.port
    $serviceName = $service.name
    $protocol = $service.protocol
    $note = $service.note
    $notes = Parse-Notes -Note $note
    $serviceObj = New-ServiceObject -Name $serviceName -Port $port -Notes $notes
    $serviceObj.Image = Get-ServiceImage -ServiceName $serviceName -Protocol $protocol -Port $port
    Write-Verbose "Assigning service '$serviceName' (protocol $protocol, port $port) to device '$hostname'" -Verbose:$Verbose
    switch ($protocol) {
        "SSH" { if (-not ($device.ssh   | Where-Object { $_.port -eq $port })) { $device.ssh += $serviceObj } }
        "SFTP" { if (-not ($device.sftp  | Where-Object { $_.port -eq $port })) { $device.sftp += $serviceObj } }
        "FTP" { if (-not ($device.ftp   | Where-Object { $_.port -eq $port })) { $device.ftp += $serviceObj } }
        "VNC" { if (-not ($device.vnc   | Where-Object { $_.port -eq $port })) { $device.vnc += $serviceObj } }
        "RDP" { if (-not ($device.rdp   | Where-Object { $_.port -eq $port })) { $device.rdp += $serviceObj } }
        "HTTP" { if (-not ($device.http  | Where-Object { $_.port -eq $port })) { $device.http += $serviceObj } }
        "HTTPS" { if (-not ($device.https | Where-Object { $_.port -eq $port })) { $device.https += $serviceObj } }
        "TCP" {
            if ($port -eq 22 -or $serviceName -like "*ssh*") {
                if (-not ($device.ssh | Where-Object { $_.port -eq $port })) { $device.ssh += $serviceObj }
            }
            elseif ($port -eq 22 -or $serviceName -like "*sftp*") {
                if (-not ($device.sftp | Where-Object { $_.port -eq $port })) { $device.sftp += $serviceObj }
            }
            elseif ($port -eq 21 -or $serviceName -like "*ftp*") {
                if (-not ($device.ftp | Where-Object { $_.port -eq $port })) { $device.ftp += $serviceObj }
            }
            elseif ($port -eq 5900 -or $serviceName -like "*vnc*") {
                if (-not ($device.vnc | Where-Object { $_.port -eq $port })) { $device.vnc += $serviceObj }
            }
            elseif ($port -eq 3389 -or $serviceName -like "*rdp*" -or $serviceName -like "*terminal*") {
                if (-not ($device.rdp | Where-Object { $_.port -eq $port })) { $device.rdp += $serviceObj }
            }
            else {
                if (-not ($device.tcp | Where-Object { $_.port -eq $port })) { $device.tcp += $serviceObj }
            }
        }
        "UDP" { if (-not ($device.udp   | Where-Object { $_.port -eq $port })) { $device.udp += $serviceObj } }
    }
}

# Generate JSON file for only the first device
if ($firstDeviceHostname) {
    $hostname = $firstDeviceHostname
    $deviceData = $devices[$hostname]
    $currentDeviceInfo = $deviceInfos[$hostname]
    if (-not $currentDeviceInfo) {
        Write-Verbose "No device info found for $hostname, using defaults." -Verbose:$Verbose
        $currentDeviceInfo = @{ name = $hostname; os = "Unknown"; ipv4 = @(); ipv6 = @(); macs = @() }
    }
    $deviceJson = [ordered]@{
        name  = $currentDeviceInfo.name
        os    = $currentDeviceInfo.os
        ipv4  = @() + $currentDeviceInfo.ipv4
        ipv6  = @() + $currentDeviceInfo.ipv6
        macs  = @() + $currentDeviceInfo.macs
        http  = @() + $deviceData.http
        https = @() + $deviceData.https
        ssh   = @() + $deviceData.ssh
        sftp  = @() + $deviceData.sftp
        ftp   = @() + $deviceData.ftp
        vnc   = @() + $deviceData.vnc
        rdp   = @() + $deviceData.rdp
        tcp   = @() + $deviceData.tcp
        udp   = @() + $deviceData.udp
    }
    if ($lastUpdated) {
        $deviceJson.lastupdated = $lastUpdated
        Write-Verbose "Added lastupdated timestamp to $($hostname): $lastUpdated" -Verbose:$Verbose
    }
    $jsonContent = $deviceJson | ConvertTo-Json -Depth 10 -Compress:$false
    Write-Verbose "Writing JSON for $hostname to $OutputFile" -Verbose:$Verbose
    $jsonContent | Out-File -FilePath $OutputFile -Encoding UTF8
    if ($Verbose) {
        Write-Host "Generated device file: $OutputFile"
        Write-Host "  - SSH services: $($deviceData.ssh.Count)"
        Write-Host "  - SFTP services: $($deviceData.sftp.Count)"
        Write-Host "  - FTP services: $($deviceData.ftp.Count)"
        Write-Host "  - VNC services: $($deviceData.vnc.Count)"
        Write-Host "  - RDP services: $($deviceData.rdp.Count)"
        Write-Host "  - HTTP services: $($deviceData.http.Count)"
        Write-Host "  - HTTPS services: $($deviceData.https.Count)"
        Write-Host "  - TCP services: $($deviceData.tcp.Count)"
        Write-Host "  - UDP services: $($deviceData.udp.Count)"
        Write-Host "  - DEBUG: deviceData content:"
        $deviceData | ConvertTo-Json -Depth 10 | Write-Host
    }
    Write-Host "Parsing complete! Generated 1 device file at '$OutputFile'"
}
else {
    Write-Host "Parsing complete! Generated 0 device file(s) at '$OutputFile'"
}
