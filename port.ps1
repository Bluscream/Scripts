param(
    [Parameter(Mandatory=$true)]
    [int[]]$Ports,
    [Parameter(Mandatory=$false)]
    [string[]]$IPs = ("192.168.2.10","192.168.2.11","192.168.2.12","100.100.1.10"),
    [Parameter(Mandatory=$false)]
    [int]$TimeoutSec = 2
)

function Test-UDPPort {
    param(
        [string]$IPAddress,
        [int]$Port,
        [int]$TimeoutMs
    )
    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Client.ReceiveTimeout = $TimeoutMs
        $remoteEndPoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($IPAddress)), $Port
        $data = [System.Text.Encoding]::ASCII.GetBytes("ping")
        $udpClient.Send($data, $data.Length, $IPAddress, $Port) | Out-Null
        $asyncResult = $udpClient.BeginReceive($null, $null)
        if ($asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $udpClient.EndReceive($asyncResult, [ref]$remoteEndPoint) | Out-Null
            $udpClient.Close()
            return $true
        } else {
            $udpClient.Close()
            return $false
        }
    } catch {
        return $false
    }
}

$jobs = @()
foreach ($ip in $IPs) {
    $jobs += Start-Job -ScriptBlock {
        param($ip, $Ports, $TimeoutSec)
        $TimeoutMs = $TimeoutSec * 1000
        # Ping
        $ping = Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds $TimeoutSec -ErrorAction SilentlyContinue
        $pingTime = if ($ping) {
            (Test-Connection -ComputerName $ip -Count 1 -TimeoutSeconds $TimeoutSec | Select-Object -ExpandProperty Latency)
        } else {
            $null
        }

        $results = @()
        foreach ($Port in $Ports) {
            # TCP
            $tcpResult = Test-NetConnection -ComputerName $ip -Port $Port -WarningAction SilentlyContinue
            $tcpObj = [PSCustomObject]@{
                IP = $ip
                Port = $Port
                Protocol = 'TCP'
                Success = $tcpResult.TcpTestSucceeded
                Ping = $pingTime
            }

            # UDP
            function Test-UDPPortInner {
                param($IPAddress, $Port, $TimeoutMs)
                try {
                    $udpClient = New-Object System.Net.Sockets.UdpClient
                    $udpClient.Client.ReceiveTimeout = $TimeoutMs
                    $remoteEndPoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($IPAddress)), $Port
                    $data = [System.Text.Encoding]::ASCII.GetBytes("ping")
                    $udpClient.Send($data, $data.Length, $IPAddress, $Port) | Out-Null
                    $asyncResult = $udpClient.BeginReceive($null, $null)
                    if ($asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                        $udpClient.EndReceive($asyncResult, [ref]$remoteEndPoint) | Out-Null
                        $udpClient.Close()
                        return $true
                    } else {
                        $udpClient.Close()
                        return $false
                    }
                } catch {
                    return $false
                }
            }
            $udpSuccess = Test-UDPPortInner $ip $Port $TimeoutMs
            $udpObj = [PSCustomObject]@{
                IP = $ip
                Port = $Port
                Protocol = 'UDP'
                Success = $udpSuccess
                Ping = $pingTime
            }

            # HTTP
            $httpSuccess = $false
            try {
                $uri = "http://$($ip):$Port/"
                $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
                if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                    $httpSuccess = $true
                }
            } catch {
                $httpSuccess = $false
            }
            $httpObj = [PSCustomObject]@{
                IP = $ip
                Port = $Port
                Protocol = 'HTTP'
                Success = $httpSuccess
                Ping = $pingTime
            }

            $results += $tcpObj
            $results += $udpObj
            $results += $httpObj
        }
        return $results
    } -ArgumentList $ip, $Ports, $TimeoutSec
}

Write-Host "Waiting for results..." -ForegroundColor Yellow
$headerPrinted = $false
$header = "{0,-15} {1,6} {2,6} {3,8} {4,8}" -f 'IP','Port','Proto','Success','Ping'
Write-Host $header -ForegroundColor Cyan
while ($jobs.Count -gt 0) {
    $finished = $jobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' -or $_.State -eq 'Stopped' }
    foreach ($job in $finished) {
        $results = Receive-Job $job
        foreach ($result in $results) {
            $color = 'White'
            if (-not $result.Success) {
                $color = 'Red'
            } elseif ($null -ne $result.Ping -and $result.Ping -lt 100) {
                $color = 'Green'
            }
            $line = "{0,-15} {1,6} {2,6} {3,8} {4,8}" -f $result.IP, $result.Port, $result.Protocol, $result.Success, ($result.Ping -ne $null ? $result.Ping : '-')
            Write-Host $line -ForegroundColor $color
        }
        Remove-Job $job
        $jobs = $jobs | Where-Object { $_.Id -ne $job.Id }
    }
    Start-Sleep -Milliseconds 200
}
