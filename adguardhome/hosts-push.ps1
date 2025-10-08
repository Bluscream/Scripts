#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Push Windows hosts file entries to AdGuardHome DNS rewrite rules
.DESCRIPTION
    Reads entries from the Windows hosts file and pushes them as DNS rewrite rules to 
    remote AdGuardHome instances. Optionally removes entries from hosts file after pushing.
    Uses the AdGuardHomeAPI class for remote access.
.PARAMETER remote
    Push to remote AdGuardHome instances
.PARAMETER local
    Write rewrite rules to a local AdGuardHome YAML configuration file
.PARAMETER localFile
    Path to the local AdGuardHome.yaml file (default: "AdguardHome.yaml")
.PARAMETER remoteHosts
    Array of AdGuardHome URLs to push rewrite rules to (used with -remote)
.PARAMETER commentTag
    Comment tag to identify entries in the hosts file to push (default: all entries)
.PARAMETER Keep
    Keep entries in hosts file after pushing them to AdGuardHome (don't remove them)
.NOTES
    For remote access: Requires AGHOME_TOKEN environment variable containing the base64-encoded auth token
    Example: $env:AGHOME_TOKEN = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:password"))
.EXAMPLE
    # Push to remote AdGuardHome instances and remove from hosts file
    .\hosts-push.ps1 -remote
.EXAMPLE
    # Write to local YAML file only
    .\hosts-push.ps1 -local -localFile "D:\AdGuardHome\AdGuardHome.yaml"
.EXAMPLE
    # Push to both local and remote
    .\hosts-push.ps1 -local -remote -localFile "AdGuardHome.yaml"
.EXAMPLE
    # Push entries with specific comment tag and keep them in hosts file
    .\hosts-push.ps1 -remote -commentTag "MyEntries" -Keep
.EXAMPLE
    # Push to multiple remote AdGuardHome instances
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
    [string]$commentTag = $null,
    [switch]$Keep
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

# Set up TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12

try {
    # Create HostsFile instance
    $hostsFile = [HostsFile]::new()
    
    # Get entries from hosts file
    Write-Host "Reading entries from Windows hosts file..."
    
    $allEntries = if ($commentTag) {
        $hostsFile.GetEntriesByComment($commentTag)
    }
    else {
        $hostsFile.GetEntries()
    }
    
    if (-not $allEntries -or $allEntries.Count -eq 0) {
        $tagInfo = if ($commentTag) { "with comment tag '$commentTag'" } else { "" }
        Write-Warning "No entries found in hosts file $tagInfo"
        exit 0
    }
    
    Write-Host "Found $($allEntries.Count) entry(ies) in hosts file"
    
    # Group entries by IP address for better processing
    $entriesByIP = @{}
    foreach ($entry in $allEntries) {
        if (-not $entriesByIP.ContainsKey($entry.IPAddress)) {
            $entriesByIP[$entry.IPAddress] = @()
        }
        $entriesByIP[$entry.IPAddress] += $entry
    }
    
    # Prepare rewrite rules
    $rewriteRules = @()
    foreach ($ip in $entriesByIP.Keys) {
        foreach ($entry in $entriesByIP[$ip]) {
            $rewriteRules += [PSCustomObject]@{
                domain = $entry.HostName
                answer = $ip
            }
        }
    }
    
    Write-Host "Prepared $($rewriteRules.Count) DNS rewrite rule(s) to push"
    
    # Track successful operations
    $successfulPushes = 0
    
    # Write to local YAML file if requested
    if ($local) {
        try {
            Write-Host "`nWriting to local AdGuardHome configuration: $localFile"
            
            if (-not (Test-Path $localFile)) {
                Write-Error "Local YAML file not found: $localFile"
            }
            else {
                # Use AdGuardHomeYaml class to manage rewrites
                $yaml = [AdGuardHomeYaml]::new($localFile)
                
                # Add new rules using the class
                $addedCount = 0
                $skippedCount = 0
                
                foreach ($rule in $rewriteRules) {
                    if ($yaml.AddRewrite($rule.domain, $rule.answer)) {
                        Write-Host "  Adding rule: $($rule.domain) -> $($rule.answer)" -ForegroundColor Green
                        $addedCount++
                    }
                    else {
                        Write-Host "  Skipping existing rule: $($rule.domain) -> $($rule.answer)" -ForegroundColor Yellow
                        $skippedCount++
                    }
                }
                
                if ($addedCount -gt 0) {
                    # Save changes (automatically creates backup)
                    $yaml.Save()
                    Write-Host "Completed local write: Added $addedCount, Skipped $skippedCount" -ForegroundColor Cyan
                    $successfulPushes++
                }
                else {
                    Write-Host "No new rules to add to local file (all exist already)" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Error "Error writing to local file ${localFile}: $_"
        }
    }
    
    # Push to remote AdGuardHome instances if requested
    if ($remote) {
    
        foreach ($remoteHost in $remoteHosts) {
            try {
                Write-Host "`nConnecting to AdGuardHome at $remoteHost..."
            
                # Create API instance from environment token
                $api = [AdGuardHomeAPI]::FromEnvironment($remoteHost)
                $api.SkipCertificateCheck = $true
            
                # Test connection
                if (-not $api.TestConnection()) {
                    Write-Error "Failed to connect to $remoteHost"
                    continue
                }
            
                Write-Host "Successfully connected to $remoteHost"
            
                # Get existing rewrite rules to avoid duplicates
                Write-Host "Checking existing rewrite rules..."
                $existingRewrites = $api.GetRewriteList()
            
                # Create lookup for existing rules
                $existingLookup = @{}
                foreach ($existing in $existingRewrites) {
                    $key = "$($existing.domain)|$($existing.answer)"
                    $existingLookup[$key] = $true
                }
            
                # Push new rewrite rules
                $addedCount = 0
                $skippedCount = 0
            
                foreach ($rule in $rewriteRules) {
                    $key = "$($rule.domain)|$($rule.answer)"
                
                    if ($existingLookup.ContainsKey($key)) {
                        Write-Host "  Skipping existing rule: $($rule.domain) -> $($rule.answer)" -ForegroundColor Yellow
                        $skippedCount++
                    }
                    else {
                        try {
                            $api.AddRewriteRule($rule.domain, $rule.answer)
                            Write-Host "  Added rule: $($rule.domain) -> $($rule.answer)" -ForegroundColor Green
                            $addedCount++
                            Start-Sleep -Milliseconds 100
                        }
                        catch {
                            Write-Error "  Failed to add rule $($rule.domain) -> $($rule.answer): $_"
                        }
                    }
                }
            
                Write-Host "Completed push to ${remoteHost}: Added $addedCount, Skipped $skippedCount" -ForegroundColor Cyan
                $successfulPushes++
            }
            catch {
                Write-Error "Error pushing to ${remoteHost}: $_"
            }
        }
    }
    
    # Remove entries from hosts file if -Keep is not specified
    if (-not $Keep -and $successfulPushes -gt 0) {
        Write-Host "`nRemoving pushed entries from hosts file..."
        
        # Backup hosts file before removing
        $hostsFile.Backup()
        
        if ($commentTag) {
            $hostsFile.RemoveEntriesByComment($commentTag)
            Write-Host "Removed entries with comment tag '$commentTag' from hosts file" -ForegroundColor Green
        }
        else {
            # Remove each specific entry
            foreach ($entry in $allEntries) {
                try {
                    $hostsFile.RemoveEntriesByHostname($entry.HostName)
                }
                catch {
                    Write-Warning "Failed to remove entry for $($entry.HostName): $_"
                }
            }
            Write-Host "Removed all pushed entries from hosts file" -ForegroundColor Green
        }
    }
    elseif ($Keep) {
        Write-Host "`nKeeping entries in hosts file (–Keep specified)" -ForegroundColor Cyan
    }
    
    if ($successfulPushes -gt 0) {
        Write-Host "`nSuccessfully pushed to $successfulPushes remote host(s)" -ForegroundColor Green
    }
    else {
        Write-Error "Failed to push to any remote hosts"
    }
}
catch {
    Write-Error "ERROR: An error occurred: $_"
    throw
}
