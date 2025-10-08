#Requires -RunAsAdministrator

# Import the base HostsFile class
using module "..\powershell\hosts.ps1"

class AdGuardHomeHosts : HostsFile {
    
    # Constructor
    AdGuardHomeHosts() : base() {
    }
    
    # Constructor with custom paths
    AdGuardHomeHosts([string]$hostsPath, [string]$backupPath, [string]$logPath) : base($hostsPath, $backupPath, $logPath) {
    }
    
    # Get effective mapping (resolve DNS chains)
    [array]GetEffectiveMapping([array]$DomainMappings) {
        $mappings = @{}
        
        # First pass: Build mapping graph
        foreach ($mapping in $DomainMappings) {
            if (-not $mappings.ContainsKey($mapping.domain)) {
                $mappings[$mapping.domain] = [PSCustomObject]@{
                    Domain  = $mapping.domain
                    Answer  = $mapping.answer
                    IsFinal = $false
                }
            }
        }

        # Second pass: Resolve final destinations
        foreach ($mapping in $mappings.Values) {
            $current = $mapping
            $visited = @{}
            while (-not $current.IsFinal) {
                # Check for circular reference
                if ($visited.ContainsKey($current.Domain)) {
                    $this.WriteLog("Circular reference detected for domain: $($current.Domain)", "WARN")
                    $current.IsFinal = $true
                    break
                }
                $visited[$current.Domain] = $true
                
                if ($current.Answer -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$') {
                    # IPv4 address - this is our final destination
                    $current.IsFinal = $true
                }
                elseif ($current.Answer -match '^([0-9a-fA-F:]+)$') {
                    # IPv6 address - this is our final destination
                    $current.IsFinal = $true
                }
                elseif ($mappings.ContainsKey($current.Answer)) {
                    # Follow the chain
                    $next = $mappings[$current.Answer]
                    if ($next.IsFinal) {
                        $current.Answer = $next.Answer
                        $current.IsFinal = $true
                    }
                    else {
                        $current.Answer = $next.Answer
                    }
                }
                else {
                    # Cannot resolve further - mark as final
                    $current.IsFinal = $true
                }
            }
        }

        return $mappings.Values.Where{ $_.IsFinal }
    }
    
    # Update from AdGuardHome instances
    [void]UpdateFromAdGuardHome([string[]]$remoteHosts, [string]$adminPassword) {
        $this.UpdateFromAdGuardHome($remoteHosts, $adminPassword, "AdGuardHome")
    }
    
    [void]UpdateFromAdGuardHome([string[]]$remoteHosts, [string]$adminPassword, [string]$commentTag) {
        # Set up TLS
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12
        
        $this.WriteLog("Starting AdGuardHome hosts update from $($remoteHosts.Count) host(s)")
        
        # Collect all mappings from all remote hosts
        $allMappings = @()
        
        foreach ($remoteHost in $remoteHosts) {
            $aghApiUrl = "$remoteHost/control/rewrite/list"
            
            try {
                $this.WriteLog("Downloading restrictions from $remoteHost...")
                $headers = @{
                    "Authorization" = "Basic $adminPassword"
                }
                $response = Invoke-WebRequest -Uri $aghApiUrl -Method Get -Headers $headers -SkipCertificateCheck

                if ($response.StatusCode -eq 200) {
                    $this.WriteLog("Successfully retrieved restrictions from $remoteHost")
                    $restrictions = ConvertFrom-Json $response.Content
                    
                    $mappings = $this.GetEffectiveMapping($restrictions)
                    $this.WriteLog("Processed $(@($mappings).Count) domain mappings from $remoteHost")
                    
                    $allMappings += $mappings
                }
                else {
                    $this.WriteLog("Failed to retrieve restrictions from ${remoteHost}: $($response.StatusCode)", "ERROR")
                }
            }
            catch {
                $this.WriteLog("Error retrieving from ${remoteHost}: $_", "ERROR")
            }
        }
        
        if ($allMappings.Count -gt 0) {
            # Backup hosts file
            $this.Backup()
            
            $this.WriteLog("Total mappings collected: $($allMappings.Count)")

            # Remove existing entries with the specified comment tag
            $this.RemoveEntriesByComment($commentTag)

            # Add new entries
            $processedIPs = @{}
            foreach ($mapping in $allMappings) {
                if ($mapping.Answer -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^([0-9a-fA-F:]+)$') {
                    if (-not $processedIPs.ContainsKey($mapping.Answer)) {
                        $domains = @($mapping.Domain)
                        foreach ($otherMapping in $allMappings) {
                            if ($otherMapping.Answer -eq $mapping.Answer -and
                                $otherMapping.Domain -ne $mapping.Domain) {
                                $domains += $otherMapping.Domain
                            }
                        }
                        $sortedDomains = $domains | Sort-Object -Unique
                        $this.AddEntry($mapping.Answer, $sortedDomains, $commentTag)
                        Start-Sleep -Milliseconds 250
                        $processedIPs[$mapping.Answer] = $true
                    }
                }
            }
            
            $this.WriteLog("Successfully updated hosts file with AdGuardHome entries")
        }
        else {
            $this.WriteLog("No mappings retrieved from any remote host", "ERROR")
        }
    }
}

# Export the class so it can be imported
Export-ModuleMember -Function * -Cmdlet * -Variable * -Alias *
