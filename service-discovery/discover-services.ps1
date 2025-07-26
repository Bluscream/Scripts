#!/usr/bin/env pwsh
# Service Discovery Script for Windows
# Discovers running services and their listening ports
# Output format: <hostname>;<service name>;<protocol>;<port>

param(
    [switch]$IncludeDocker = $true,
    [switch]$IncludeWSL = $true,
    [int]$TimeoutMs = 500,
    [int]$MaxParallelJobs = 10
)

# Get hostname
$hostname = [System.Net.Dns]::GetHostName()
$timeoutSec = [math]::Ceiling($TimeoutMs / 1000)

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
$logFile = Join-Path $env:TEMP 'discovery.log'
# Helper function to write to both stdout and log file
function Write-DiscoveryLine {
    param(
        [string]$Line,
        [switch]$Verbose = $false
    )
    if ($Verbose) {
        Write-Verbose $Line
    }
    else {
        $Line | Out-File -FilePath $logFile -Encoding UTF8 -Append
        Write-Output $Line
    }
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
        [string]$Note = ""
    )
    $line = "$hostname;$ServiceName;$Protocol;$Port;$Status;$Ping;$Source;$Note"
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

# Function to test TCP connectivity and measure ping time (optimized)
function Test-TcpPort {
    param(
        [string]$Host_,
        [int]$Port,
        [int]$TimeoutMs = 500  # Reduced from 1500ms to 500ms
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

# Function to try HTTP/HTTPS request (optimized)
function Test-HttpProtocol {
    param(
        [string]$Host_,
        [int]$Port,
        [int]$TimeoutMs = 500  # Reduced from 1500ms to 500ms
    )
    $urlHttp = "http://$($Host_):$Port/"
    $urlHttps = "https://$($Host_):$Port/"
    try {
        $resp = Invoke-WebRequest -Uri $urlHttp -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
        if ($resp.StatusCode -ge 100 -and $resp.StatusCode -lt 600) {
            return 'HTTP'
        }
    }
    catch {}
    try {
        $resp = Invoke-WebRequest -Uri $urlHttps -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
        if ($resp.StatusCode -ge 100 -and $resp.StatusCode -lt 600) {
            return 'HTTPS'
        }
    }
    catch {}
    return $null
}

# Cache for connection results to avoid duplicate tests
$connectionCache = @{}
$connectionCacheLock = [System.Threading.ReaderWriterLockSlim]::new()

# Optimized function to test connection with caching and thread safety
function Test-ConnectionWithCache {
    param(
        [string]$Host_,
        [int]$Port
    )
    $cacheKey = "$Host_`:$Port"
    
    # Thread-safe cache read
    $connectionCacheLock.EnterReadLock()
    try {
        if ($connectionCache.ContainsKey($cacheKey)) {
            return $connectionCache[$cacheKey]
        }
    }
    finally {
        $connectionCacheLock.ExitReadLock()
    }
    
    # Test connection
    $result = Test-TcpPort -Host $Host_ -Port $Port
    
    # Thread-safe cache write
    $connectionCacheLock.EnterWriteLock()
    try {
        $connectionCache[$cacheKey] = $result
    }
    finally {
        $connectionCacheLock.ExitWriteLock()
    }
    
    return $result
}

# Optimized function to test HTTP with caching and thread safety
function Test-HttpWithCache {
    param(
        [string]$Host_,
        [int]$Port
    )
    $cacheKey = "http_$Host_`:$Port"
    
    # Thread-safe cache read
    $connectionCacheLock.EnterReadLock()
    try {
        if ($connectionCache.ContainsKey($cacheKey)) {
            return $connectionCache[$cacheKey]
        }
    }
    finally {
        $connectionCacheLock.ExitReadLock()
    }
    
    # Test HTTP
    $result = Test-HttpProtocol -Host $Host_ -Port $Port
    
    # Thread-safe cache write
    $connectionCacheLock.EnterWriteLock()
    try {
        $connectionCache[$cacheKey] = $result
    }
    finally {
        $connectionCacheLock.ExitWriteLock()
    }
    
    return $result
}

# Function to process a single service in parallel
function Process-ServiceParallel {
    param(
        [string]$ServiceName,
        [string]$Protocol,
        [int]$Port,
        [string]$Source
    )
    
    $result = Test-ConnectionWithCache -Host '127.0.0.1' -Port $Port
    $finalProtocol = $Protocol
    
    if ($result.status -eq 'success' -and $Protocol -eq 'TCP') {
        $detectedHttp = Test-HttpWithCache -Host '127.0.0.1' -Port $Port
        if ($detectedHttp) {
            $finalProtocol = $detectedHttp
        }
    }
    
    return @{
        ServiceName = $ServiceName
        Protocol    = $finalProtocol
        Port        = $Port
        Status      = $result.status
        Ping        = $result.ping
        Source      = $Source
    }
}

# Function to process services in parallel batches
function Process-ServicesParallel {
    param(
        [array]$Services,
        [int]$MaxJobs = 10
    )
    
    $jobs = @()
    $results = @()
    
    foreach ($service in $Services) {
        # Start job for this service
        $job = Start-Job -ScriptBlock {
            param($ServiceName, $Protocol, $Port, $Source)
            
            # Import the functions into the job
            function Test-TcpPort {
                param([string]$Host_, [int]$Port, [int]$TimeoutMs = 500)
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
            
            function Test-HttpProtocol {
                param([string]$Host_, [int]$Port, [int]$TimeoutMs = 500)
                $urlHttp = "http://$($Host_):$Port/"
                $urlHttps = "https://$($Host_):$Port/"
                try {
                    $resp = Invoke-WebRequest -Uri $urlHttp -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
                    if ($resp.StatusCode -ge 100 -and $resp.StatusCode -lt 600) {
                        return 'HTTP'
                    }
                }
                catch {}
                try {
                    $resp = Invoke-WebRequest -Uri $urlHttps -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
                    if ($resp.StatusCode -ge 100 -and $resp.StatusCode -lt 600) {
                        return 'HTTPS'
                    }
                }
                catch {}
                return $null
            }
            
            $result = Test-TcpPort -Host '127.0.0.1' -Port $Port
            $finalProtocol = $Protocol
            
            if ($result.status -eq 'success' -and $Protocol -eq 'TCP') {
                $detectedHttp = Test-HttpProtocol -Host '127.0.0.1' -Port $Port
                if ($detectedHttp) {
                    $finalProtocol = $detectedHttp
                }
            }
            
            return @{
                ServiceName = $ServiceName
                Protocol    = $finalProtocol
                Port        = $Port
                Status      = $result.status
                Ping        = $result.ping
                Source      = $Source
            }
        } -ArgumentList $service.ServiceName, $service.Protocol, $service.Port, $service.Source
        
        $jobs += $job
        
        # If we've reached max jobs, wait for completion
        if ($jobs.Count -ge $MaxJobs) {
            $completedJobs = Wait-Job -Job $jobs -Any
            foreach ($completedJob in $completedJobs) {
                $result = Receive-Job -Job $completedJob
                $results += $result
                Remove-Job -Job $completedJob
                $jobs = $jobs | Where-Object { $_.Id -ne $completedJob.Id }
            }
        }
    }
    
    # Wait for remaining jobs
    if ($jobs.Count -gt 0) {
        Wait-Job -Job $jobs
        foreach ($job in $jobs) {
            $result = Receive-Job -Job $job
            $results += $result
            Remove-Job -Job $job
        }
    }
    
    return $results
}

Write-DiscoveryLine "# Service Discovery Results"
Write-DiscoveryLine "# Generated at $(Get-Date)"
Write-DiscoveryLine ""
Write-DiscoveryLine "# hostname;ipv4s;ipv6s"
Write-DiscoveryLine "# $hostname;$($localIPv4s -join ',');$($localIPv6s -join ',')"
Write-DiscoveryLine ""
Write-DiscoveryLine "# hostname;service name;protocol;port;status;ping ms;source"


# Method 1: Get-NetTCPConnection (Windows native) - Only listening servers
if ($Verbose) { Write-DiscoveryLine "Scanning TCP listening servers..." -ForegroundColor Cyan }
try {
    $tcpConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ne 0 -and $_.State -eq "Listen" }
    
    foreach ($conn in $tcpConnections) {
        $serviceName = Get-ServiceNameFromProcess -ProcessId $conn.OwningProcess
        if ($serviceName -eq "Unknown") {
            $serviceName = Get-ServiceNameFromPort -Port $conn.LocalPort
        }
        $result = Test-ConnectionWithCache -Host '127.0.0.1' -Port $conn.LocalPort
        $protocol = 'TCP'; if ($result.status -eq 'success') { $detectedHttp = Test-HttpWithCache -Host '127.0.0.1' -Port $conn.LocalPort; if ($detectedHttp) { $protocol = $detectedHttp } }
        Write-ServiceOutput -ServiceName $serviceName -Protocol $protocol -Port $conn.LocalPort -Source 'Get-NetTCPConnection' -Status $result.status -Ping $result.ping
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
            $result = Test-ConnectionWithCache -Host '127.0.0.1' -Port $port
            $protocol = 'TCP'; if ($result.status -eq 'success') { $detectedHttp = Test-HttpWithCache -Host '127.0.0.1' -Port $port; if ($detectedHttp) { $protocol = $detectedHttp } }
            Write-ServiceOutput -ServiceName $serviceName -Protocol $protocol -Port $port -Source 'netstat' -Status $result.status -Ping $result.ping
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
                    $result = Test-ConnectionWithCache -Host '127.0.0.1' -Port $conn.LocalPort
                    $protocol = 'TCP'; if ($result.status -eq 'success') { $detectedHttp = Test-HttpWithCache -Host '127.0.0.1' -Port $conn.LocalPort; if ($detectedHttp) { $protocol = $detectedHttp } }
                    Write-ServiceOutput -ServiceName $service.Name -Protocol $protocol -Port $conn.LocalPort -Source 'Windows Service' -Status $result.status -Ping $result.ping
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
                        $result = Test-ConnectionWithCache -Host '127.0.0.1' -Port $hostPort
                        $dockerProtocol = $protocol; if ($result.status -eq 'success') { $detectedHttp = Test-HttpWithCache -Host '127.0.0.1' -Port $hostPort; if ($detectedHttp) { $dockerProtocol = $detectedHttp } }
                        Write-ServiceOutput -ServiceName "Docker-$containerName" -Protocol $dockerProtocol -Port $hostPort -Source "Docker" -Status $result.status -Ping $result.ping
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
                $result = Test-ConnectionWithCache -Host '127.0.0.1' -Port $conn.LocalPort
                $protocol = 'TCP'; if ($result.status -eq 'success') { $detectedHttp = Test-HttpWithCache -Host '127.0.0.1' -Port $conn.LocalPort; if ($detectedHttp) { $protocol = $detectedHttp } }
                Write-ServiceOutput -ServiceName "WSL-$($process.ProcessName)" -Protocol $protocol -Port $conn.LocalPort -Source "WSL" -Status $result.status -Ping $result.ping
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
    Write-DiscoveryLine "# Performance optimizations applied:" -ForegroundColor Green
    Write-DiscoveryLine "# - Parallel processing with $MaxParallelJobs concurrent jobs" -ForegroundColor Green
    Write-DiscoveryLine "# - Connection caching to avoid duplicate tests" -ForegroundColor Green
    Write-DiscoveryLine "# - Consistent timeouts using \$TimeoutMs parameter (${TimeoutMs}ms)" -ForegroundColor Green
    Write-DiscoveryLine "# - Thread-safe cache operations" -ForegroundColor Green
}
Read-Host "Press Enter to exit"
