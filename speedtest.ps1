param(
    [string]$Server = "29320",
    [int]$ThrottleLimit = 5,
    [switch]$Parallel = $false
)

class PingResult {
    [double]$Jitter
    [double]$Latency
    [double]$Low
    [double]$High
    
    PingResult([PSCustomObject]$data) {
        $this.Jitter = $data.jitter
        $this.Latency = $data.latency
        $this.Low = $data.low
        $this.High = $data.high
    }
}

class LatencyMetrics {
    [double]$Iqm
    [double]$Low
    [double]$High
    [double]$Jitter
    
    LatencyMetrics([PSCustomObject]$data) {
        $this.Iqm = $data.iqm
        $this.Low = $data.low
        $this.High = $data.high
        $this.Jitter = $data.jitter
    }
}

class TransferMetrics {
    [long]$Bandwidth
    [long]$Bytes
    [int]$Elapsed
    [LatencyMetrics]$Latency
    
    TransferMetrics([PSCustomObject]$data) {
        $this.Bandwidth = $data.bandwidth
        $this.Bytes = $data.bytes
        $this.Elapsed = $data.elapsed
        if ($data.latency) {
            $this.Latency = [LatencyMetrics]::new($data.latency)
        }
    }
}

class InterfaceInfo {
    [string]$InternalIp
    [string]$Name
    [string]$MacAddr
    [bool]$IsVpn
    [string]$ExternalIp
    
    InterfaceInfo([PSCustomObject]$data) {
        $this.InternalIp = $data.internalIp
        $this.Name = $data.name
        $this.MacAddr = $data.macAddr
        $this.IsVpn = $data.isVpn
        $this.ExternalIp = $data.externalIp
    }
}

class ServerInfo {
    [int]$Id
    [string]$Host
    [int]$Port
    [string]$Name
    [string]$Location
    [string]$Country
    [string]$Ip
    
    ServerInfo([PSCustomObject]$data) {
        $this.Id = $data.id
        $this.Host = $data.host
        $this.Port = $data.port
        $this.Name = $data.name
        $this.Location = $data.location
        $this.Country = $data.country
        $this.Ip = $data.ip
    }
}

class ResultInfo {
    [string]$Id
    [string]$Url
    [bool]$Persisted
    
    ResultInfo([PSCustomObject]$data) {
        $this.Id = $data.id
        $this.Url = $data.url
        $this.Persisted = $data.persisted
    }
}

class SpeedTestResult {
    [datetime]$Timestamp
    [PingResult]$Ping
    [TransferMetrics]$Download
    [TransferMetrics]$Upload
    [double]$PacketLoss
    [string]$Isp
    [InterfaceInfo]$Interface
    [ServerInfo]$Server
    [ResultInfo]$Result
    
    SpeedTestResult([PSCustomObject]$data) {
        $this.Timestamp = [datetime]::Parse($data.timestamp)
        $this.Ping = [PingResult]::new($data.ping)
        $this.Download = [TransferMetrics]::new($data.download)
        $this.Upload = [TransferMetrics]::new($data.upload)
        $this.PacketLoss = $data.packetLoss
        $this.Isp = $data.isp
        $this.Interface = [InterfaceInfo]::new($data.interface)
        $this.Server = [ServerInfo]::new($data.server)
        $this.Result = [ResultInfo]::new($data.result)
    }
    
    # Helper method to get download speed in Mbps
    [double] GetDownloadMbps() {
        return [Math]::Round(($this.Download.Bandwidth * 8) / 1000000, 2)
    }
    
    # Helper method to get upload speed in Mbps
    [double] GetUploadMbps() {
        return [Math]::Round(($this.Upload.Bandwidth * 8) / 1000000, 2)
    }
    
    # Helper method to format result as string
    [string] ToString() {
        return "SpeedTest: $($this.Interface.Name) | Down: $($this.GetDownloadMbps()) Mbps | Up: $($this.GetUploadMbps()) Mbps | Ping: $($this.Ping.Latency) ms | Jitter: $($this.Ping.Jitter) ms"
    }
}

# Find speedtest executable
function Find-Speedtest {
    $paths = @(
        "speedtest.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Ookla.Speedtest.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\speedtest.exe",
        "$PSScriptRoot\speedtest.exe"
    )
    
    foreach ($path in $paths) {
        if (Get-Command $path -ErrorAction SilentlyContinue) {
            return $path
        }
        if (Test-Path $path -ErrorAction SilentlyContinue) {
            return $path
        }
    }
    
    throw "speedtest.exe not found. Please install Ookla Speedtest CLI from winget or place speedtest.exe in the script directory."
}

# Run speedtest and return parsed result
function RunSpeedTest {
    param(
        [hashtable]$InterfaceInfo,
        [string]$SpeedtestPath,
        [int]$Index,
        [int]$Total
    )
    
    $activityId = [Math]::Abs($InterfaceInfo.name.GetHashCode()) % 1000
    
    try {
        Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Starting..." -PercentComplete 0
        
        $ErrorActionPreference = "Continue"
        
        # Build arguments
        $speedtestArgs = @(
            "--format=json",
            "--progress=yes",
            "--accept-license",
            "--accept-gdpr"
        )
        
        if ($InterfaceInfo.ipv4) {
            $speedtestArgs += "-i", $InterfaceInfo.ipv4
        }
        
        if ($InterfaceInfo.server) {
            $speedtestArgs += "-s", $InterfaceInfo.server
        }
        
        Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Running speed test..." -PercentComplete 25
        
        # Run speedtest and capture output
        $output = & $SpeedtestPath $speedtestArgs 2>&1 | Out-String
        
        if ($LASTEXITCODE -ne 0) {
            Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Failed" -PercentComplete 100 -Completed
            Write-Host "[$($InterfaceInfo.name)] Speed test failed (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            return $null
        }
        
        Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Parsing results..." -PercentComplete 90
        
        # Parse JSON output (filter to result type only)
        $jsonLines = $output -split "`n" | Where-Object { $_.Trim() -ne "" }
        $resultJson = $null
        
        foreach ($line in $jsonLines) {
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.type -eq "result") {
                    $resultJson = $obj
                    break
                }
            }
            catch {
                # Skip non-JSON lines
            }
        }
        
        if ($resultJson) {
            $result = [SpeedTestResult]::new($resultJson)
            # Populate the interface name since speedtest doesn't include it
            if ([string]::IsNullOrEmpty($result.Interface.Name)) {
                $result.Interface.Name = $InterfaceInfo.name
            }
            Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Complete!" -PercentComplete 100 -Completed
            Write-Host "[$($InterfaceInfo.name)] ✓ Complete" -ForegroundColor Green
            return $result
        }
        else {
            Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Failed to parse" -PercentComplete 100 -Completed
            Write-Host "[$($InterfaceInfo.name)] Failed to parse JSON output" -ForegroundColor Yellow
            return $null
        }
    }
    catch {
        Write-Progress -Id $activityId -Activity $InterfaceInfo.name -Status "Error" -PercentComplete 100 -Completed
        Write-Host "[$($InterfaceInfo.name)] Error: $_" -ForegroundColor Red
        return $null
    }
}

# Display results in a nice table
function Show-ResultsTable {
    param([SpeedTestResult[]]$Results)
    
    if (-not $Results -or @($Results).Count -eq 0) {
        Write-Host "`nNo results to display." -ForegroundColor Yellow
        return
    }
    
    Write-Host "`n" -NoNewline
    Write-Host ("═" * 120) -ForegroundColor Cyan
    Write-Host "  SPEED TEST RESULTS" -ForegroundColor Cyan
    Write-Host ("═" * 120) -ForegroundColor Cyan
    
    $tableData = $Results | ForEach-Object {
        [PSCustomObject]@{
            Interface  = $_.Interface.Name
            IP         = $_.Interface.InternalIp
            Download   = "$($_.GetDownloadMbps()) Mbps"
            Upload     = "$($_.GetUploadMbps()) Mbps"
            Ping       = "$([Math]::Round($_.Ping.Latency, 2)) ms"
            Jitter     = "$([Math]::Round($_.Ping.Jitter, 2)) ms"
            PacketLoss = "$([Math]::Round($_.PacketLoss, 2))%"
            Server     = "$($_.Server.Name), $($_.Server.Location)"
            ISP        = $_.Isp
        }
    }
    
    $tableData | Format-Table -AutoSize
    
    Write-Host ("═" * 120) -ForegroundColor Cyan
    Write-Host ""
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Find speedtest executable
try {
    $speedtestPath = Find-Speedtest
    Write-Host "Found speedtest at: $speedtestPath" -ForegroundColor DarkGray
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}

# Display network interfaces
Write-Host "`nDetected Network Interfaces:" -ForegroundColor Cyan
$totalInterfaces = Get-NetIPConfiguration
Format-Table -InputObject $totalInterfaces -Property @{Label = "Status"; Expression = { $_.NetAdapter.Status } }, InterfaceAlias, InterfaceDescription, @{Label = "IPv4DefaultGateway"; Expression = { $_.IPv4DefaultGateway.NextHop -join ', ' } } -AutoSize

# Filter interfaces to test
$networkInterfaces = $totalInterfaces | 
Where-Object {
    $_.IPv4DefaultGateway -ne $null -and 
    $_.NetAdapter.Status -eq "Up"
}

Write-Host "Testing $(@($networkInterfaces).Count)/$(@($totalInterfaces).Count) network interfaces`n" -ForegroundColor DarkGray

# Build interface details list
$interfaceDetails = @()
foreach ($interface in $networkInterfaces) {
    $ipv4Addresses = $interface.IPv4Address.IPAddress
    foreach ($ipv4_ in $ipv4Addresses) {
        $interfaceDetails += @{
            name        = "$($interface.InterfaceAlias)"
            description = $interface.InterfaceDescription
            ipv4        = $ipv4_
            server      = $Server
        }
    }
}

# Run speed tests
$results = @()
$useParallel = ($Parallel -and $($PSVersionTable.PSVersion.Major -ge 7))

if ($useParallel) {
    Write-Host "Running tests in parallel (ThrottleLimit: $ThrottleLimit)...`n" -ForegroundColor Cyan
    
    # Prepare initialization script with all class and function definitions
    $initScript = [scriptblock]::Create(@"
# Class definitions
$((Get-Content $PSCommandPath -Raw -ErrorAction Stop).Split('Set-StrictMode')[0])

# Function definitions
function Find-Speedtest {
    $(${function:Find-Speedtest}.ToString())
}

function RunSpeedTest {
    $(${function:RunSpeedTest}.ToString())
}
"@)
    
    # Use ThreadJobs for parallel execution
    $jobs = @()
    $index = 0
    foreach ($if in $interfaceDetails) {
        # Throttle: wait if we've hit the limit
        while (@(Get-Job -State Running).Count -ge $ThrottleLimit) {
            Start-Sleep -Milliseconds 100
        }
        
        $index++
        $job = Start-ThreadJob -Name "SpeedTest-$($if.name)" -InitializationScript $initScript -ScriptBlock {
            param($InterfaceInfo, $SpeedtestPath, $Index, $Total)
            RunSpeedTest -InterfaceInfo $InterfaceInfo -SpeedtestPath $SpeedtestPath -Index $Index -Total $Total
        } -ArgumentList $if, $speedtestPath, $index, $interfaceDetails.Count
        
        $jobs += $job
        
        # Delay to avoid rate limiting from speedtest servers
        Start-Sleep -Seconds 2
    }
    
    # Wait for all jobs to complete and collect results
    Write-Host "Waiting for all tests to complete...`n" -ForegroundColor DarkGray
    $jobs | Wait-Job | Out-Null
    
    foreach ($job in $jobs) {
        $result = Receive-Job -Job $job
        if ($result) {
            $results += $result
        }
        Remove-Job -Job $job
    }
}
else {
    Write-Host "Running tests sequentially...`n" -ForegroundColor Cyan
    
    $total = $interfaceDetails.Count
    $index = 0
    foreach ($if in $interfaceDetails) {
        $index++
        $result = RunSpeedTest -InterfaceInfo $if -SpeedtestPath $speedtestPath -Index $index -Total $total
        if ($result) {
            $results += $result
        }
    }
}

# Filter out null results and display
$results = $results | Where-Object { $_ -ne $null }
Show-ResultsTable -Results $results