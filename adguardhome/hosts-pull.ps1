#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Sync AdGuardHome DNS rewrite rules to Windows hosts file
.DESCRIPTION
    Downloads DNS rewrite rules from remote AdGuardHome instances and/or local YAML configuration
    file and adds them to the Windows hosts file. Uses the AdGuardHomeAPI class for remote access.
    
    Supports DNS chain resolution (domain -> domain -> IP) to find final IP addresses.
.PARAMETER remote
    Fetch rewrite rules from remote AdGuardHome instances
.PARAMETER local
    Read rewrite rules from a local AdGuardHome YAML configuration file
.PARAMETER localFile
    Path to the local AdGuardHome.yaml file (default: "AdguardHome.yaml")
.PARAMETER remoteHosts
    Array of AdGuardHome URLs to pull rewrite rules from (used with -remote)
.PARAMETER commentTag
    Comment tag to identify entries managed by this script in the hosts file
.NOTES
    For remote access: Requires AGHOME_TOKEN environment variable containing the base64-encoded auth token
    Example: $env:AGHOME_TOKEN = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:password"))
.EXAMPLE
    # Pull from remote AdGuardHome instances only
    .\hosts-push.ps1 -remote
.EXAMPLE
    # Read from local YAML file only
    .\hosts-push.ps1 -local -localFile "D:\AdGuardHome\AdGuardHome.yaml"
.EXAMPLE
    # Combine both local and remote sources
    .\hosts-push.ps1 -local -remote -localFile "AdGuardHome.yaml"
.EXAMPLE
    # Pull from multiple remote hosts
    .\hosts-push.ps1 -remote -remoteHosts @("https://192.168.2.4:3003", "https://10.0.0.5:3000")
#>

#Requires -RunAsAdministrator

# Import the HostsFile class and AdGuardHome classes
using module "..\powershell\hosts.ps1"
using module "..\powershell\aghome-api.ps1"
using module "..\powershell\aghome-yaml.ps1"

param(
    [switch]$remote,
    [switch]$local,
    [string]$localFile = "AdguardHome.yaml",
    [string[]]$remoteHosts = @("https://192.168.2.4:3003"),
    [string]$commentTag = "AdGuardHome"
)

# Ensure powershell-yaml module is installed
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'powershell-yaml module not found. Installing...'
    Install-Module powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
}

if (!($remote -or $local)) {
    Write-Warning "Neither -remote nor -local was specified! Using -remote by default."
    $remote = $true
}

# AdGuardHome-specific function to resolve DNS chains
function Get-EffectiveMapping {
    param($DomainMappings)
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
                Write-Host "Circular reference detected for domain: $($current.Domain)"
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

# Function to get rewrites from YAML file using AdGuardHomeYaml class
function Get-RewritesFromYaml {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        throw "YAML file not found: $FilePath"
    }
    
    $yaml = [AdGuardHomeYaml]::new($FilePath)
    $rewrites = $yaml.GetRewrites()
    
    if (-not $rewrites -or $rewrites.Count -eq 0) {
        Write-Warning "No rewrites found in local file"
    }
    
    return $rewrites
}

# Set up TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12

try {
    # Create HostsFile instance
    $hostsFile = [HostsFile]::new()
    
    # Collect all mappings from all sources
    $allMappings = @()
    
    # Process local file if requested
    if ($local) {
        Write-Host "Reading local AdGuardHome configuration from: $localFile"
        
        try {
            $localRestrictions = Get-RewritesFromYaml -FilePath $localFile
            
            if ($localRestrictions -and $localRestrictions.Count -gt 0) {
                Write-Host "Successfully read $($localRestrictions.Count) rewrites from local file"
                
                # Use AdGuardHomeYaml class for effective mapping resolution
                $yamlObj = [AdGuardHomeYaml]::new($localFile)
                $mappings = $yamlObj.GetEffectiveMappings()
                Write-Host "Processed $(@($mappings).Count) domain mappings from local file"
                
                $allMappings += $mappings
            }
            else {
                Write-Warning "No rewrites found in local file"
            }
        }
        catch {
            Write-Error "Error reading local file: $_"
        }
    }
    
    # Process remote hosts if requested
    if ($remote) {
        Write-Host "Starting AdGuardHome hosts file update from $($remoteHosts.Count) remote host(s)"
        
        foreach ($remoteHost in $remoteHosts) {
            try {
                Write-Host "Connecting to AdGuardHome at $remoteHost..."
                
                # Create API instance from environment token
                $api = [AdGuardHomeAPI]::FromEnvironment($remoteHost)
                $api.SkipCertificateCheck = $true
                
                # Test connection
                if (-not $api.TestConnection()) {
                    Write-Error "Failed to connect to $remoteHost"
                    continue
                }
                
                Write-Host "Downloading restrictions from $remoteHost..."
                
                # Get rewrite rules using API
                $restrictions = $api.GetRewriteList()
                
                if ($restrictions) {
                    Write-Host "Successfully retrieved restrictions from $remoteHost"
                    
                    $mappings = Get-EffectiveMapping -DomainMappings $restrictions
                    Write-Host "Processed $(@($mappings).Count) domain mappings from $remoteHost"
                    
                    $allMappings += $mappings
                }
                else {
                    Write-Error "No restrictions retrieved from $remoteHost"
                }
            }
            catch {
                Write-Error "Error retrieving from ${remoteHost}: $_"
            }
        }
    }
    
    if ($allMappings.Count -gt 0) {
        # Backup hosts file
        $hostsFile.Backup()
        
        Write-Host "Total mappings collected: $($allMappings.Count)"

        # Remove existing entries with the specified comment tag
        $hostsFile.RemoveEntriesByComment($commentTag)

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
                    $hostsFile.AddEntry($mapping.Answer, $sortedDomains, $commentTag)
                    Start-Sleep -Milliseconds 250
                    $processedIPs[$mapping.Answer] = $true
                }
            }
        }
        
        Write-Host "Successfully updated hosts file with AdGuardHome entries"
    }
    else {
        Write-Error "No mappings retrieved from any remote host"
    }
}
catch {
    Write-Error "ERROR: An error occurred: $_"
    throw
}