# Configuration
$aghApiUrl = "https://192.168.2.4:3003/control/rewrite/list"
$adminPassword = $env:AGHOME_TOKEN
$logPath = "$env:TEMP\AdGuardHome_Hosts_Update.log"

# Set up logging
function Write-Log {
    param($Message, $Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $logEntry
    if ($Level -eq "ERROR") {
        Write-Error $logEntry
    } else {
        Write-Host $logEntry
    }
}

function Get-EffectiveMapping {
    param($DomainMappings)
    $mappings = @{}
    
    # First pass: Build mapping graph
    foreach ($mapping in $DomainMappings) {
        if (-not $mappings.ContainsKey($mapping.domain)) {
            $mappings[$mapping.domain] = [PSCustomObject]@{
                Domain = $mapping.domain
                Answer = $mapping.answer
                IsFinal = $false
            }
        }
    }

    # Second pass: Resolve final destinations
    foreach ($mapping in $mappings.Values) {
        $current = $mapping
        while (-not $current.IsFinal) {
            if ($current.Answer -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$') {
                # IPv4 address - this is our final destination
                $current.IsFinal = $true
            } elseif ($current.Answer -match '^([0-9a-fA-F:]+)$') {
                # IPv6 address - this is our final destination
                $current.IsFinal = $true
            } elseif ($mappings.ContainsKey($current.Answer)) {
                # Follow the chain
                $next = $mappings[$current.Answer]
                if ($next.IsFinal) {
                    $current.Answer = $next.Answer
                    $current.IsFinal = $true
                } else {
                    $current.Answer = $next.Answer
                }
            } else {
                # Cannot resolve further - mark as final
                $current.IsFinal = $true
            }
        }
    }

    return $mappings.Values.Where{$_.IsFinal}
}

if (-not (Get-Command "Get-HostEntry" -ErrorAction SilentlyContinue)) {
    try {
        Install-Module PsHosts -Force -ErrorAction Stop
        Write-Log "Installed PsHosts module"
    } catch {
        Write-Log "Failed to install PsHosts module: $_" -Error
        Exit-PSHostProcess 1
    }
}


# Set up TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12

try {
    # Initialize logging
    if (-not (Test-Path $logPath)) {
        New-Item -Path $logPath -ItemType File | Out-Null
    }
    Write-Log "Starting AdGuardHome hosts file update"

    # Download the restrictions list
    Write-Log "Downloading restrictions from AdGuardHome..."
    $headers = @{
        "Authorization" = "Basic $adminPassword"
    }
    $response = Invoke-WebRequest -Uri $aghApiUrl -Method Get -Headers $headers -SkipCertificateCheck

    if ($response.StatusCode -eq 200) {
        Write-Log "Successfully retrieved restrictions"
        # Parse JSON response
        $restrictions = ConvertFrom-Json $response.Content
        
        # Create backup of existing hosts file
        $hostsPath = "$env:windir\System32\drivers\etc\hosts"
        $backupPath = "$hostsPath.bak"
        
        if (Test-Path $hostsPath) {
            Copy-Item -Path $hostsPath -Destination $backupPath -Force
            Write-Log "Created backup of hosts file"
        }
        
        # Process restrictions
        $mappings = Get-EffectiveMapping -DomainMappings $restrictions
        Write-Log "Processed $(@($mappings).Count) domain mappings"

        # Get current hosts entries
        $currentEntries = Get-HostEntry
        
        # Remove existing AdGuardHome entries
        $currentEntries | Where-Object {
            -not ($_.Comment -match "AdGuardHome")
        } | Remove-HostEntry

        # Add new AdGuardHome entries
        foreach ($mapping in $mappings) {
            if ($mapping.Answer -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^([0-9a-fA-F:]+)$') {
                if (-not (Get-HostEntry | Where-Object {$_.IPAddress -eq $mapping.Answer})) {
                    $domains = @($mapping.Domain)
                    foreach ($otherMapping in $mappings) {
                        if ($otherMapping.Answer -eq $mapping.Answer -and
                            $otherMapping.Domain -ne $mapping.Domain) {
                            $domains += $otherMapping.Domain
                        }
                    }
                    $sortedDomains = $domains | Sort-Object
                    foreach ($domain in $sortedDomains) {
                        Set-HostEntry $domain $mapping.Answer -Comment "AdGuardHome" -Force
                        Write-Log "Added hosts entry for $($mapping.Answer) with domain: $domain"
                        Start-Sleep -Milliseconds 250
                    }
                    # Write-Log "Added hosts entry for $($mapping.Answer) with domains: $($sortedDomains -join ', ')"
                }
            }
        }
        
        Write-Log "Successfully updated hosts file"
    }
    else {
        throw "Failed to retrieve restrictions: $($response.StatusCode)"
    }
}
catch {
    Write-Log "ERROR: An error occurred: $_" -Level "ERROR"
    throw
}
finally {
    Write-Log "Update process completed"
}