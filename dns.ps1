param(
  [switch]$test,
  [string]$testDomain = "google.com"
)


$dnsservers = @{
  "localhost"     = @(
    "127.0.0.1", "::1"
  )
  "fritzbox"      = @(
    "192.168.2.1"
  )
  "hass"          = @(
    "192.168.2.4", "fe80::360a:cf28:dbb7:3bc9",
    "192.168.2.5", "fe80::a50f:919f:47b3:c4c1",
    "100.100.1.4", "fd7a:115c:a1e0::5c01:d661"
  );
  "nas"           = @(
    "192.168.2.10", "fe80::1e1b:dff:fe76:8bf3"
    "192.168.2.12",
    "100.100.1.10", "fd7a:115c:a1e0::401:1e62"
  );
  "homeserver"    = @(
    "192.168.2.38", "fd00::ba98:a7bb:ac07:57fd",
    "192.168.2.39", "fd00::505f:c63a:83df:2561",
    "100.100.1.38"
  );
  "adguarddns"    = @(
    "94.140.14.14", "2a10:50c0::ad1:ff",
    "94.140.15.15", "2a10:50c0::ad2:ff"
  )
  "cloudflaredns" = @(
    "1.1.1.1", "2606:4700:4700::1111",
    "1.0.0.1", "2606:4700:4700::1001"
  )
  "tailscale"     = @("100.100.100.100")
}

$whitelist = @() # @("2.5GB Ethernet")
$blacklist = @("Tailscale") # @("Powerline", "Wi-Fi")

$dns = $dnsservers["localhost"] # + $dnsservers["fritzbox"] + $dnsservers["tailscale"] + $dnsservers["hass"] + $dnsservers["homeserver"] + $dnsservers["nas"] + $dnsservers["adguarddns"] + $dnsservers["cloudflaredns"]

$useWorkingOnly = $true

function Test-DNSServers($servers, $testDomain) {
  Write-Host "`nTesting DNS Servers with domain: $testDomain" -ForegroundColor Cyan
  
  $jobs = @()
  foreach ($server in $servers) {
    $jobs += Start-Job -ScriptBlock {
      param($srv, $domain)
      $result = @{
        Server  = $srv
        Success = $false
        Time    = $null
        IP      = $null
        Error   = $null
      }
      
      try {
        $startTime = Get-Date
        $nslookupOutput = nslookup $domain $srv 2>&1 | Out-String
        $endTime = Get-Date
        $result.Time = [math]::Round(($endTime - $startTime).TotalMilliseconds, 2)
        
        # Check for timeout
        if ($nslookupOutput -match "DNS request timed out|timeout|timed-out") {
          $result.Error = "Timeout"
        }
        # Check for other errors
        elseif ($nslookupOutput -match "server failed|SERVFAIL|can't find|No response from server") {
          $result.Error = "Server failed"
        }
        # Look for successful resolution - must have "Name:" line with the domain
        elseif ($nslookupOutput -match "Name:\s+$domain") {
          # Extract the actual resolved IP addresses (after the Name: line)
          $lines = $nslookupOutput -split "`n"
          $nameLineFound = $false
          $resolvedIPs = @()
          
          foreach ($line in $lines) {
            if ($line -match "Name:\s+$domain") {
              $nameLineFound = $true
              continue
            }
            if ($nameLineFound) {
              # Match "Addresses: <ip>" or continuation lines with just whitespace and IP
              if ($line -match "^\s*Address(?:es)?:\s+(.+)") {
                $ip = $matches[1].Trim()
                # Make sure it's not the DNS server's own IP
                if ($ip -ne $srv) {
                  $resolvedIPs += $ip
                }
              }
              # Match continuation lines (just whitespace followed by IP)
              elseif ($line -match "^\s+([0-9a-fA-F:.]+)\s*$") {
                $ip = $matches[1].Trim()
                if ($ip -ne $srv) {
                  $resolvedIPs += $ip
                }
              }
              # Stop at next section (non-whitespace at start, not Address line)
              elseif ($line -match "^[A-Za-z]") {
                break
              }
            }
          }
          
          if ($resolvedIPs.Count -gt 0) {
            $result.Success = $true
            $result.IP = $resolvedIPs -join ", "
          }
          else {
            $result.Error = "No valid IP returned"
          }
        }
        else {
          $result.Error = "Failed to resolve"
        }
      }
      catch {
        $result.Error = $_.Exception.Message
      }
      
      return $result
    } -ArgumentList $server, $testDomain
  }
  
  Write-Host "Waiting for DNS tests to complete..." -ForegroundColor Yellow
  $results = $jobs | Wait-Job | Receive-Job
  $jobs | Remove-Job
  
  Write-Host "`nDNS Test Results:" -ForegroundColor Cyan
  Write-Host ("=" * 90) -ForegroundColor Gray
  Write-Host ("{0,-32} {1,-10} {2,-15} {3}" -f "Server", "Status", "Time (ms)", "IP/Error") -ForegroundColor White
  Write-Host ("=" * 90) -ForegroundColor Gray
  
  foreach ($result in $results) {
    $statusText = if ($result.Success) { "OK" } else { "FAILED" }
    $statusColor = if ($result.Success) { "Green" } else { "Red" }
    $timeText = if ($result.Time) { $result.Time } else { "N/A" }
    $infoText = if ($result.Success) { $result.IP } else { $result.Error }
    
    Write-Host ("{0,-32} " -f $result.Server) -NoNewline
    Write-Host ("{0,-10} " -f $statusText) -ForegroundColor $statusColor -NoNewline
    Write-Host ("{0,-15} " -f $timeText) -ForegroundColor Cyan -NoNewline
    Write-Host $infoText -ForegroundColor Gray
  }
  
  Write-Host ("=" * 90) -ForegroundColor Gray
  
  $successCount = ($results | Where-Object { $_.Success }).Count
  $totalCount = $results.Count
  Write-Host "`nSummary: $successCount/$totalCount servers responded successfully" -ForegroundColor $(if ($successCount -eq $totalCount) { "Green" } else { "Yellow" })
  
  # Return successful servers sorted by response time (fastest first)
  $successfulServers = $results | Where-Object { $_.Success } | Sort-Object Time | Select-Object -ExpandProperty Server
  return $successfulServers
}
if ($useWorkingOnly) {
  Write-Host "Using only working DNS Servers"
  $dns = Test-DNSServers -servers $dns -testDomain $testDomain
}
Write-Host "$($dns.Count) DNS Servers: $($dns -join ", ")"

if ($test) {
  Read-Host "Press Enter to continue"
  return
}

Write-Host "`nChecking if Administrator..."
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {  
  $arguments = "& '" + $myinvocation.mycommand.definition + "'"
  Start-Process powershell -Verb runAs -ArgumentList $arguments
  Break
}
try {
  $profiles = Get-NetConnectionProfile -ErrorAction Stop | Select-Object InterfaceAlias, InterfaceIndex
}
catch {
  Write-Host "Get-NetConnectionProfile is not available. Falling back to Get-NetAdapter."
  $profiles = Get-NetAdapter | Select-Object Name, InterfaceIndex
}

foreach ($k in $profiles) {
  # Get-NetAdapter Get-DnsClientServerAddress
  [string]$devstr = "{0} ({1})" -f $k.InterfaceAlias, $k.InterfaceIndex
  $whitelisted = (-not $whitelist -or $whitelist.Count -eq 0) -or ($whitelist -contains $k.InterfaceAlias)
  $blacklisted = $k.InterfaceAlias -in $blacklist
  if ($whitelisted -and -not $blacklisted) {
    Write-Host "Changing DNS for $devstr"
    Set-DNSClientServerAddress -InterfaceIndex $k.InterfaceIndex -ServerAddresses $dns
  }
  else {
    Write-Host "Resetting DNS for $devstr"
    Set-DNSClientServerAddress -InterfaceIndex $k.InterfaceIndex -ResetServerAddresses
  }
}

ipconfig /flushdns

nslookup $testDomain
  
# $Nic1 = (Get-DnsClientServerAddress | where {}).InterfaceAlias
  
# Set-DNSClientServerAddress "InterfaceAlias" –ServerAddresses ("preferred-DNS-address", "alternate-DNS-address")
Pause