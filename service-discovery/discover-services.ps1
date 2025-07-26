#!/usr/bin/env pwsh
# Service Discovery Script for Windows
# Discovers running services and their listening ports
# Output format: <hostname>;<service name>;<protocol>;<port>

param(
    [switch]$IncludeDocker = $true,
    [switch]$IncludeWSL = $true
)

# Get hostname
$hostname = [System.Net.Dns]::GetHostName()

# Get all local IP addresses (IPv4 and IPv6)
$localIPv4s = @()
$localIPv6s = @()
try {
    $networkInterfaces = Get-NetIPAddress -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "::1" -and $_.IPAddress -notlike "fe80:*" }
    $localIPv4s = $networkInterfaces | Where-Object { $_.AddressFamily -eq "IPv4" } | ForEach-Object { $_.IPAddress } | Sort-Object -Unique
    $localIPv6s = $networkInterfaces | Where-Object { $_.AddressFamily -eq "IPv6" } | ForEach-Object { $_.IPAddress } | Sort-Object -Unique
}
catch {
    # Fallback to hostname if IP detection fails
    $localIPv4s = @($hostname)
    $localIPv6s = @()
}

# Helper function to write to both stdout and log file
function Write-DiscoveryLine {
    param(
        [string]$Line
    )
    $logFile = Join-Path $env:TEMP 'discovery.log'
    $Line | Out-File -FilePath $logFile -Encoding UTF8 -Append
    Write-Output $Line
}

# Function to write output in required format
function Write-ServiceOutput {
    param(
        [string]$ServiceName,
        [string]$Protocol,
        [string]$Port,
        [string]$Status = "",
        [string]$Ping = "",
        [string]$Source = "",
        [string]$DetectedProtocol = ""
    )
    $outProto = if ($DetectedProtocol) { $DetectedProtocol } else { $Protocol }
    $line = "$hostname;$ServiceName;$outProto;$Port;$Status;$Ping;$Source"
    Write-DiscoveryLine $line
}

# Function to get service name from process
function Get-ServiceNameFromProcess {
    param([int]$ProcessId)
    
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            return $process.ProcessName
        }
    }
    catch {
        # Process might not exist anymore
    }
    return "Unknown"
}

# Function to get service name from port
function Get-ServiceNameFromPort {
    param([int]$Port)
    
    # Common port mappings
    $portMap = @{
        21    = "FTP"
        22    = "SSH"
        23    = "Telnet"
        25    = "SMTP"
        53    = "DNS"
        80    = "HTTP"
        110   = "POP3"
        143   = "IMAP"
        443   = "HTTPS"
        993   = "IMAPS"
        995   = "POP3S"
        1433  = "MSSQL"
        1521  = "Oracle"
        3306  = "MySQL"
        3389  = "RDP"
        5432  = "PostgreSQL"
        5900  = "VNC"
        6379  = "Redis"
        8080  = "HTTP-Alt"
        8443  = "HTTPS-Alt"
        9000  = "Jenkins"
        27017 = "MongoDB"
    }
    
    if ($portMap.ContainsKey($Port)) {
        return $portMap[$Port]
    }
    return "Unknown"
}

# Function to test TCP connectivity and measure ping time
function Test-TcpPort {
    param(
        [string]$Host_,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )
    $tcpClient = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $iar = $tcpClient.BeginConnect($Host_, $Port, $null, $null)
        $success = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $sw.Stop()
        if ($success -and $tcpClient.Connected) {
            $tcpClient.EndConnect($iar)
            $tcpClient.Close()
            return @{ status = 'success'; ping = $sw.ElapsedMilliseconds }
        }
        else {
            $tcpClient.Close()
            return @{ status = 'timeout'; ping = $sw.ElapsedMilliseconds }
        }
    }
    catch {
        $sw.Stop()
        return @{ status = 'refused'; ping = $sw.ElapsedMilliseconds }
    }
    finally {
        if ($tcpClient) { $tcpClient.Dispose() }
    }
}

# Function to try HTTP/HTTPS request
function Test-HttpProtocol {
    param(
        [string]$Host_,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )
    $urlHttp = "http://$($Host_):$Port/"
    $urlHttps = "https://$($Host_):$Port/"
    try {
        $resp = Invoke-WebRequest -Uri $urlHttp -UseBasicParsing -TimeoutSec ([math]::Ceiling($TimeoutMs / 1000)) -ErrorAction Stop
        if ($resp.StatusCode -ge 100 -and $resp.StatusCode -lt 600) {
            return 'HTTP'
        }
    }
    catch {}
    try {
        $resp = Invoke-WebRequest -Uri $urlHttps -UseBasicParsing -TimeoutSec ([math]::Ceiling($TimeoutMs / 1000)) -ErrorAction Stop
        if ($resp.StatusCode -ge 100 -and $resp.StatusCode -lt 600) {
            return 'HTTPS'
        }
    }
    catch {}
    return $null
}

Write-DiscoveryLine "# Service Discovery Results"
Write-DiscoveryLine "# Generated at $(Get-Date)"
Write-DiscoveryLine ""
Write-DiscoveryLine "# hostname;ipv4s;ipv6s"
Write-DiscoveryLine "# hostname;service name;protocol;port;status;ping ms;source"
Write-DiscoveryLine ""
Write-DiscoveryLine "#hostname;service name;protocol;port;status;ping ms;source"


# Method 1: Get-NetTCPConnection (Windows native) - Only listening servers
if ($Verbose) { Write-DiscoveryLine "Scanning TCP listening servers..." -ForegroundColor Cyan }
try {
    $tcpConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ne 0 -and $_.State -eq "Listen" }
    
    foreach ($conn in $tcpConnections) {
        $serviceName = Get-ServiceNameFromProcess -ProcessId $conn.OwningProcess
        if ($serviceName -eq "Unknown") {
            $serviceName = Get-ServiceNameFromPort -Port $conn.LocalPort
        }
        $result = Test-TcpPort -Host '127.0.0.1' -Port $conn.LocalPort
        $httpProto = $null; if ($result.status -eq 'success') { $httpProto = Test-HttpProtocol -Host '127.0.0.1' -Port $conn.LocalPort }
        Write-ServiceOutput -ServiceName $serviceName -Protocol 'TCP' -Port $conn.LocalPort -Source 'Get-NetTCPConnection' -Status $result.status -Ping $result.ping -DetectedProtocol $httpProto
    }
}
catch {
    if ($Verbose) { Write-DiscoveryLine "Get-NetTCPConnection failed: $($_.Exception.Message)" -ForegroundColor Red }
}

# Method 2: netstat (fallback) - Only listening servers
if ($Verbose) { Write-DiscoveryLine "Scanning with netstat (listening only)..." -ForegroundColor Cyan }
try {
    $netstatOutput = netstat -an | Select-String "LISTENING"
    
    foreach ($line in $netstatOutput) {
        if ($line -match "TCP\s+(\d+\.\d+\.\d+\.\d+):(\d+)\s+0\.0\.0\.0:0\s+LISTENING\s+(\d+)") {
            $port = $matches[2]
            $processId = $matches[3]
            $serviceName = Get-ServiceNameFromProcess -ProcessId $processId
            if ($serviceName -eq "Unknown") {
                $serviceName = Get-ServiceNameFromPort -Port $port
            }
            $result = Test-TcpPort -Host '127.0.0.1' -Port $port
            $httpProto = $null; if ($result.status -eq 'success') { $httpProto = Test-HttpProtocol -Host '127.0.0.1' -Port $port }
            Write-ServiceOutput -ServiceName $serviceName -Protocol 'TCP' -Port $port -Source 'netstat' -Status $result.status -Ping $result.ping -DetectedProtocol $httpProto
        }
    }
}
catch {
    if ($Verbose) { Write-DiscoveryLine "netstat failed: $($_.Exception.Message)" -ForegroundColor Red }
}

# Method 3: Get Windows Services - Only services that are actually listening
if ($Verbose) { Write-DiscoveryLine "Scanning Windows Services (listening only)..." -ForegroundColor Cyan }
try {
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" }
    
    foreach ($service in $services) {
        # Try to find if the service is listening on any port
        $serviceProcess = Get-WmiObject -Class Win32_Service -Filter "Name='$($service.Name)'" -ErrorAction SilentlyContinue
        if ($serviceProcess -and $serviceProcess.ProcessId) {
            $tcpConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $serviceProcess.ProcessId -and $_.State -eq "Listen" }
            
            if ($tcpConnections) {
                foreach ($conn in $tcpConnections) {
                    $result = Test-TcpPort -Host '127.0.0.1' -Port $conn.LocalPort
                    $httpProto = $null; if ($result.status -eq 'success') { $httpProto = Test-HttpProtocol -Host '127.0.0.1' -Port $conn.LocalPort }
                    Write-ServiceOutput -ServiceName $service.Name -Protocol 'TCP' -Port $conn.LocalPort -Source 'Windows Service' -Status $result.status -Ping $result.ping -DetectedProtocol $httpProto
                }
            }
        }
    }
}
catch {
    if ($Verbose) { Write-DiscoveryLine "Windows Services scan failed: $($_.Exception.Message)" -ForegroundColor Red }
}

# Method 4: Docker containers (if Docker is available) - Only exposed ports
if ($IncludeDocker) {
    if ($Verbose) { Write-DiscoveryLine "Scanning Docker containers (exposed ports only)..." -ForegroundColor Cyan }
    try {
        $dockerPs = docker ps --format "table {{.Names}}\t{{.Ports}}" 2>$null
        if ($dockerPs) {
            foreach ($line in $dockerPs) {
                if ($line -match "(\S+)\s+(.+)") {
                    $containerName = $matches[1]
                    $ports = $matches[2]
                    
                    # Parse port mappings like "0.0.0.0:8080->80/tcp" (only exposed ports)
                    if ($ports -match "(\d+\.\d+\.\d+\.\d+):(\d+)->(\d+)/(\w+)") {
                        $hostPort = $matches[2]
                        $containerPort = $matches[3]
                        $protocol = $matches[4].ToUpper()
                        $result = Test-TcpPort -Host '127.0.0.1' -Port $hostPort
                        $httpProto = $null; if ($result.status -eq 'success') { $httpProto = Test-HttpProtocol -Host '127.0.0.1' -Port $hostPort }
                        Write-ServiceOutput -ServiceName "Docker-$containerName" -Protocol $protocol -Port $hostPort -Source "Docker" -Status $result.status -Ping $result.ping -DetectedProtocol $httpProto
                    }
                }
            }
        }
    }
    catch {
        if ($Verbose) { Write-DiscoveryLine "Docker scan failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# Method 5: WSL processes (if WSL is available) - Only listening servers
if ($IncludeWSL) {
    if ($Verbose) { Write-DiscoveryLine "Scanning WSL processes (listening only)..." -ForegroundColor Cyan }
    try {
        $wslProcesses = Get-Process | Where-Object { $_.ProcessName -like "*wsl*" -or $_.ProcessName -like "*ubuntu*" -or $_.ProcessName -like "*debian*" }
        
        foreach ($process in $wslProcesses) {
            $tcpConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $process.Id -and $_.State -eq "Listen" }
            
            foreach ($conn in $tcpConnections) {
                $result = Test-TcpPort -Host '127.0.0.1' -Port $conn.LocalPort
                $httpProto = $null; if ($result.status -eq 'success') { $httpProto = Test-HttpProtocol -Host '127.0.0.1' -Port $conn.LocalPort }
                Write-ServiceOutput -ServiceName "WSL-$($process.ProcessName)" -Protocol "TCP" -Port $conn.LocalPort -Source "WSL" -Status $result.status -Ping $result.ping -DetectedProtocol $httpProto
            }
        }
    }
    catch {
        if ($Verbose) { Write-DiscoveryLine "WSL scan failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# Method 6: Check for UDP services (less common but important) - Only listening servers
if ($Verbose) { Write-DiscoveryLine "Scanning UDP listening servers..." -ForegroundColor Cyan }
try {
    $udpConnections = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ne 0 }
    
    foreach ($conn in $udpConnections) {
        $serviceName = Get-ServiceNameFromProcess -ProcessId $conn.OwningProcess
        if ($serviceName -eq "Unknown") {
            $serviceName = Get-ServiceNameFromPort -Port $conn.LocalPort
        }
        Write-ServiceOutput -ServiceName $serviceName -Protocol "UDP" -Port $conn.LocalPort -Source "Get-NetUDPEndpoint"
    }
}
catch {
    if ($Verbose) { Write-DiscoveryLine "UDP scan failed: $($_.Exception.Message)" -ForegroundColor Red }
}

if ($Verbose) {
    Write-DiscoveryLine ""
    Write-DiscoveryLine "# Scan completed at $(Get-Date)" -ForegroundColor Yellow
}
Read-Host "Press Enter to exit"
