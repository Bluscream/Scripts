using namespace System.Collections.Generic

<#
.SYNOPSIS
    AdGuard Home YAML Configuration Management Class
.DESCRIPTION
    A PowerShell class for managing AdGuard Home YAML configuration files,
    specifically for DNS rewrite rules operations.
.NOTES
    Requires powershell-yaml module
#>

class AdGuardHomeYaml {
    [string]$YamlPath
    [object]$Config
    
    # Constructor
    AdGuardHomeYaml([string]$yamlPath) {
        $this.YamlPath = $yamlPath
        
        # Ensure powershell-yaml module is installed
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            Write-Host 'powershell-yaml module not found. Installing...'
            Install-Module powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
        }
        
        if (-not (Test-Path $yamlPath)) {
            throw "YAML file not found: $yamlPath"
        }
        
        $this.Load()
    }
    
    # Load YAML configuration from file
    [void] Load() {
        $content = Get-Content $this.YamlPath -Raw
        $this.Config = $content | ConvertFrom-Yaml
        
        # Initialize filtering.rewrites if it doesn't exist
        if (-not $this.Config.filtering) {
            $this.Config.filtering = @{}
        }
        if (-not $this.Config.filtering.rewrites) {
            $this.Config.filtering.rewrites = @()
        }
    }
    
    # Create a backup of the YAML file
    [string] Backup() {
        return $this.Backup("$($this.YamlPath).bak")
    }
    
    # Create a backup of the YAML file with custom path
    [string] Backup([string]$backupPath) {
        if (Test-Path $this.YamlPath) {
            Copy-Item -Path $this.YamlPath -Destination $backupPath -Force
            Write-Verbose "Created backup: $backupPath"
            return $backupPath
        }
        else {
            throw "Source YAML file not found: $($this.YamlPath)"
        }
    }
    
    # Save YAML configuration to file
    [void] Save() {
        $this.Save($this.YamlPath)
    }
    
    # Save YAML configuration to specified file
    [void] Save([string]$outputPath) {
        $backupPath = "$outputPath.bak"
        if (Test-Path $outputPath) {
            Copy-Item -Path $outputPath -Destination $backupPath -Force
            Write-Verbose "Created backup: $backupPath"
        }
        
        $this.Config | ConvertTo-Yaml | Out-File -FilePath $outputPath -Encoding UTF8
        Write-Verbose "Saved configuration to: $outputPath"
    }
    
    # Get all rewrite rules
    [array] GetRewrites() {
        $rewrites = @()
        if ($this.Config.filtering.rewrites) {
            foreach ($rewrite in $this.Config.filtering.rewrites) {
                $rewrites += [PSCustomObject]@{
                    domain = $rewrite.domain
                    answer = $rewrite.answer
                }
            }
        }
        return $rewrites
    }
    
    # Get rewrite rules by domain
    [array] GetRewritesByDomain([string]$domain) {
        return $this.GetRewrites() | Where-Object { $_.domain -eq $domain }
    }
    
    # Get rewrite rules by answer (IP address)
    [array] GetRewritesByAnswer([string]$answer) {
        return $this.GetRewrites() | Where-Object { $_.answer -eq $answer }
    }
    
    # Check if a rewrite rule exists
    [bool] RewriteExists([string]$domain, [string]$answer) {
        foreach ($rewrite in $this.Config.filtering.rewrites) {
            if ($rewrite.domain -eq $domain -and $rewrite.answer -eq $answer) {
                return $true
            }
        }
        return $false
    }
    
    # Add a new rewrite rule
    [bool] AddRewrite([string]$domain, [string]$answer) {
        if ($this.RewriteExists($domain, $answer)) {
            Write-Verbose "Rewrite already exists: $domain -> $answer"
            return $false
        }
        
        $this.Config.filtering.rewrites += @{
            domain = $domain
            answer = $answer
        }
        
        Write-Verbose "Added rewrite: $domain -> $answer"
        return $true
    }
    
    # Add multiple rewrite rules
    [hashtable] AddRewrites([array]$rewrites) {
        $result = @{
            Added   = 0
            Skipped = 0
        }
        
        foreach ($rewrite in $rewrites) {
            if ($this.AddRewrite($rewrite.domain, $rewrite.answer)) {
                $result.Added++
            }
            else {
                $result.Skipped++
            }
        }
        
        return $result
    }
    
    # Update/Set a rewrite rule (remove old, add new)
    [bool] SetRewrite([string]$oldDomain, [string]$oldAnswer, [string]$newDomain, [string]$newAnswer) {
        if ($this.RemoveRewrite($oldDomain, $oldAnswer)) {
            return $this.AddRewrite($newDomain, $newAnswer)
        }
        return $false
    }
    
    # Remove a specific rewrite rule
    [bool] RemoveRewrite([string]$domain, [string]$answer) {
        $removed = $false
        $newRewrites = @()
        
        foreach ($rewrite in $this.Config.filtering.rewrites) {
            if ($rewrite.domain -eq $domain -and $rewrite.answer -eq $answer) {
                Write-Verbose "Removed rewrite: $domain -> $answer"
                $removed = $true
            }
            else {
                $newRewrites += $rewrite
            }
        }
        
        if ($removed) {
            $this.Config.filtering.rewrites = $newRewrites
        }
        
        return $removed
    }
    
    # Remove all rewrite rules for a specific domain
    [int] RemoveRewritesByDomain([string]$domain) {
        $removedCount = 0
        $newRewrites = @()
        
        foreach ($rewrite in $this.Config.filtering.rewrites) {
            if ($rewrite.domain -eq $domain) {
                Write-Verbose "Removed rewrite: $($rewrite.domain) -> $($rewrite.answer)"
                $removedCount++
            }
            else {
                $newRewrites += $rewrite
            }
        }
        
        if ($removedCount -gt 0) {
            $this.Config.filtering.rewrites = $newRewrites
        }
        
        return $removedCount
    }
    
    # Remove all rewrite rules for a specific answer (IP address)
    [int] RemoveRewritesByAnswer([string]$answer) {
        $removedCount = 0
        $newRewrites = @()
        
        foreach ($rewrite in $this.Config.filtering.rewrites) {
            if ($rewrite.answer -eq $answer) {
                Write-Verbose "Removed rewrite: $($rewrite.domain) -> $($rewrite.answer)"
                $removedCount++
            }
            else {
                $newRewrites += $rewrite
            }
        }
        
        if ($removedCount -gt 0) {
            $this.Config.filtering.rewrites = $newRewrites
        }
        
        return $removedCount
    }
    
    # Clear all rewrite rules
    [void] ClearRewrites() {
        $count = $this.Config.filtering.rewrites.Count
        $this.Config.filtering.rewrites = @()
        Write-Verbose "Cleared all $count rewrite rules"
    }
    
    # Remove duplicate rewrite rules (keeping first occurrence)
    [int] DeduplicateRewrites() {
        $seen = @{}
        $uniqueRewrites = @()
        $duplicateCount = 0
        
        foreach ($rewrite in $this.Config.filtering.rewrites) {
            $key = "$($rewrite.domain)|$($rewrite.answer)"
            
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $uniqueRewrites += $rewrite
            }
            else {
                Write-Verbose "Removing duplicate: $($rewrite.domain) -> $($rewrite.answer)"
                $duplicateCount++
            }
        }
        
        if ($duplicateCount -gt 0) {
            $this.Config.filtering.rewrites = $uniqueRewrites
            Write-Verbose "Removed $duplicateCount duplicate rewrite rule(s)"
        }
        
        return $duplicateCount
    }
    
    # Get count of rewrite rules
    [int] GetRewriteCount() {
        return $this.Config.filtering.rewrites.Count
    }
    
    # Export rewrites to JSON
    [string] ExportRewritesToJson() {
        return ($this.GetRewrites() | ConvertTo-Json -Depth 10)
    }
    
    # Export rewrites to JSON file
    [void] ExportRewritesToJson([string]$outputPath) {
        $this.ExportRewritesToJson() | Out-File -FilePath $outputPath -Encoding UTF8
        Write-Verbose "Exported rewrites to JSON: $outputPath"
    }
    
    # Import rewrites from JSON
    [hashtable] ImportRewritesFromJson([string]$jsonPath) {
        if (-not (Test-Path $jsonPath)) {
            throw "JSON file not found: $jsonPath"
        }
        
        $rewrites = Get-Content $jsonPath -Raw | ConvertFrom-Json
        return $this.AddRewrites($rewrites)
    }
    
    # Get effective DNS mapping (resolve chains: domain -> domain -> IP)
    [array] GetEffectiveMappings() {
        $mappings = @{}
        
        # First pass: Build mapping graph
        foreach ($rewrite in $this.Config.filtering.rewrites) {
            if (-not $mappings.ContainsKey($rewrite.domain)) {
                $mappings[$rewrite.domain] = [PSCustomObject]@{
                    Domain  = $rewrite.domain
                    Answer  = $rewrite.answer
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
                    Write-Warning "Circular reference detected for domain: $($current.Domain)"
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
        
        return $mappings.Values | Where-Object { $_.IsFinal }
    }
}

# Export the class
Export-ModuleMember -Function * -Cmdlet * -Variable * -Alias *
