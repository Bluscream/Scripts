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

function RunSpeedTest($if) {
    Write-Host -ForegroundColor DarkGray "[$($if.name)] Starting speed test"
    try {
        $ErrorActionPreference = "Continue"
        speedtest.exe -i $if.ipv4 -s $if.server
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[$($if.name)] Speed test completed" -ForegroundColor Green
        }
        else {
            Write-Host "[$($if.name)] Speed test failed (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[$($if.name)] Error running speed test: $_" -ForegroundColor Red
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command "Set-ConsoleFont" -ErrorAction SilentlyContinue)) {
    try {
        Install-Module WindowsConsoleFonts -ErrorAction Stop
    }
    catch {}
}
if (Get-Command "Set-ConsoleFont" -ErrorAction SilentlyContinue) {
    Get-ConsoleFont | Select-Object -ExpandProperty Name | Set-ConsoleFont -Size 5
}
$totalInterfaces = Get-NetIPConfiguration
Format-Table -InputObject $totalInterfaces -Property @{Label = "Status"; Expression = { $_.NetAdapter.Status } }, InterfaceAlias, InterfaceDescription, @{Label = "IPv4DefaultGateway"; Expression = { $_.IPv4DefaultGateway.NextHop -join ', ' } } -AutoSize
$networkInterfaces = $totalInterfaces | 
Where-Object {
    $_.IPv4DefaultGateway -ne $null -and 
    $_.NetAdapter.Status -eq "Up"
}
Write-Host -ForegroundColor DarkGray "Testing $(@($networkInterfaces).Count)/$(@($totalInterfaces).Count) network interfaces"

$interfaceDetails = @()
foreach ($interface in $networkInterfaces) {
    $ipv4Addresses = $interface.IPv4Address.IPAddress
    foreach ($ipv4_ in $ipv4Addresses) {
        $interfaceDetails += @{
            name   = "$($interface.InterfaceAlias) ($($interface.InterfaceDescription)): $ipv4_"
            ipv4   = $ipv4_
            server = $server
        }
    }
}
$funcDef = ${function:RunSpeedTest}.ToString()

$useParallel = ($Parallel -and $($PSVersionTable.PSVersion.Major -ge 7))
if ($useParallel) {
    $interfaceDetails | ForEach-Object -Parallel {
        ${function:RunSpeedTest} = $using:funcDef
        RunSpeedTest $_
    } -ThrottleLimit $ThrottleLimit
}
else {
    foreach ($if in $interfaceDetails) {
        RunSpeedTest $if
    }
}