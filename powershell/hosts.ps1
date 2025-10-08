#Requires -RunAsAdministrator

class HostsFile {
    [string]$HostsPath
    [string]$BackupPath
    
    # Constructor
    HostsFile() {
        $this.HostsPath = "$env:windir\System32\drivers\etc\hosts"
        $this.BackupPath = "$($this.HostsPath).bak"
        $this.EnsurePsHostsInstalled()
    }
    
    # Constructor with custom paths
    HostsFile([string]$hostsPath, [string]$backupPath) {
        $this.HostsPath = $hostsPath
        $this.BackupPath = $backupPath
        $this.EnsurePsHostsInstalled()
    }
    
    # Ensure PsHosts module is installed
    [void]EnsurePsHostsInstalled() {
        if (-not (Get-Command "Get-HostEntry" -ErrorAction SilentlyContinue)) {
            try {
                Install-Module PsHosts -Force -ErrorAction Stop
                Write-Host "Installed PsHosts module"
            }
            catch {
                Write-Error "Failed to install PsHosts module: $_"
                throw "PsHosts module installation failed: $_"
            }
        }
    }
    
    # Backup hosts file
    [void]Backup() {
        if (Test-Path $this.HostsPath) {
            Copy-Item -Path $this.HostsPath -Destination $this.BackupPath -Force
            Write-Host "Created backup of hosts file at $($this.BackupPath)"
        }
        else {
            Write-Error "Hosts file not found at $($this.HostsPath)"
            throw "Hosts file not found"
        }
    }
    
    # Backup with custom path
    [void]Backup([string]$customBackupPath) {
        if (Test-Path $this.HostsPath) {
            Copy-Item -Path $this.HostsPath -Destination $customBackupPath -Force
            Write-Host "Created backup of hosts file at $customBackupPath"
        }
        else {
            Write-Error "Hosts file not found at $($this.HostsPath)"
            throw "Hosts file not found"
        }
    }
    
    # Restore from backup
    [void]Restore() {
        if (Test-Path $this.BackupPath) {
            Copy-Item -Path $this.BackupPath -Destination $this.HostsPath -Force
            Write-Host "Restored hosts file from backup"
        }
        else {
            Write-Error "Backup file not found at $($this.BackupPath)"
            throw "Backup file not found"
        }
    }
    
    # Restore from custom path
    [void]Restore([string]$customBackupPath) {
        if (Test-Path $customBackupPath) {
            Copy-Item -Path $customBackupPath -Destination $this.HostsPath -Force
            Write-Host "Restored hosts file from $customBackupPath"
        }
        else {
            Write-Error "Backup file not found at $customBackupPath"
            throw "Backup file not found"
        }
    }
    
    # Get all host entries
    [array]GetEntries() {
        return Get-HostEntry
    }
    
    # Get entries by comment
    [array]GetEntriesByComment([string]$comment) {
        return Get-HostEntry | Where-Object { $_.Comment -match $comment }
    }
    
    # Get entries by IP address
    [array]GetEntriesByIP([string]$ipAddress) {
        return Get-HostEntry | Where-Object { $_.IPAddress -eq $ipAddress }
    }
    
    # Get entries by hostname
    [array]GetEntriesByHostname([string]$hostname) {
        return Get-HostEntry | Where-Object { $_.HostName -eq $hostname }
    }
    
    # Add host entry
    [void]AddEntry([string]$ipAddress, [string[]]$hostnames) {
        foreach ($hostname in $hostnames) {
            Set-HostEntry $hostname $ipAddress -Force
            Write-Host "Added entry: $ipAddress -> $hostname"
        }
    }
    
    # Add host entry with comment
    [void]AddEntry([string]$ipAddress, [string[]]$hostnames, [string]$comment) {
        foreach ($hostname in $hostnames) {
            Set-HostEntry $hostname $ipAddress -Comment $comment -Force
            Write-Host "Added entry: $ipAddress -> $hostname (Comment: $comment)"
        }
    }
    
    # Remove entries by IP address
    [void]RemoveEntriesByIP([string]$ipAddress) {
        $entries = Get-HostEntry | Where-Object { $_.IPAddress -eq $ipAddress }
        if ($entries) {
            $entries | Remove-HostEntry
            Write-Host "Removed $(@($entries).Count) entry(ies) for IP address: $ipAddress"
        }
        else {
            Write-Host "No entry found for IP address: $ipAddress"
        }
    }
    
    # Remove entries by hostname
    [void]RemoveEntriesByHostname([string]$hostname) {
        $entries = Get-HostEntry | Where-Object { $_.HostName -eq $hostname }
        if ($entries) {
            $entries | Remove-HostEntry
            Write-Host "Removed entry for hostname: $hostname"
        }
        else {
            Write-Host "No entry found for hostname: $hostname"
        }
    }
    
    # Remove hostname from entries (removes entire entry only if no hostnames left)
    [void]RemoveHostname([string]$hostname) {
        $entries = Get-HostEntry | Where-Object { $_.HostName -eq $hostname }
        if ($entries) {
            foreach ($entry in $entries) {
                # Check if this IP has other hostnames
                $allEntriesForIP = Get-HostEntry | Where-Object { $_.IPAddress -eq $entry.IPAddress }
                
                if (@($allEntriesForIP).Count -gt 1) {
                    # Multiple hostnames for this IP, just remove this specific hostname
                    Remove-HostEntry -HostName $hostname
                    Write-Host "Removed hostname '$hostname' from IP $($entry.IPAddress) (other hostnames remain)"
                }
                else {
                    # Only hostname for this IP, remove the entire entry
                    Remove-HostEntry -HostName $hostname
                    Write-Host "Removed entry for hostname '$hostname' from IP $($entry.IPAddress) (was the only hostname)"
                }
            }
        }
        else {
            Write-Host "No entry found for hostname: $hostname"
        }
    }
    
    # Remove entries by comment
    [void]RemoveEntriesByComment([string]$comment) {
        $entries = Get-HostEntry | Where-Object { $_.Comment -match $comment }
        if ($entries) {
            $entries | Remove-HostEntry
            Write-Host "Removed $(@($entries).Count) entries with comment matching: $comment"
        }
        else {
            Write-Host "No entries found with comment matching: $comment"
        }
    }
    
    # Remove entries NOT matching a comment (keep only specific entries)
    [void]KeepOnlyEntriesByComment([string]$comment) {
        $entries = Get-HostEntry | Where-Object { -not ($_.Comment -match $comment) }
        if ($entries) {
            $entries | Remove-HostEntry
            Write-Host "Removed $(@($entries).Count) entries NOT matching comment: $comment"
        }
    }
    
    # Clear all entries
    [void]ClearAll() {
        $entries = Get-HostEntry
        if ($entries) {
            $entries | Remove-HostEntry
            Write-Host "Cleared all host entries"
        }
    }
    
    # Export hosts file to JSON
    [string]ExportToJson() {
        $entries = $this.GetEntries()
        return ($entries | ConvertTo-Json -Depth 10)
    }
    
    # Export hosts file to JSON file
    [void]ExportToJson([string]$outputPath) {
        $json = $this.ExportToJson()
        $json | Out-File -FilePath $outputPath -Encoding UTF8
        Write-Host "Exported hosts file to JSON: $outputPath"
    }
    
    # Import from JSON
    [void]ImportFromJson([string]$jsonPath, [string]$comment) {
        if (Test-Path $jsonPath) {
            $entries = Get-Content $jsonPath -Raw | ConvertFrom-Json
            foreach ($entry in $entries) {
                if ($entry.HostName -and $entry.IPAddress) {
                    $this.AddEntry($entry.IPAddress, @($entry.HostName), $comment)
                }
            }
            Write-Host "Imported $(@($entries).Count) entries from JSON: $jsonPath"
        }
        else {
            Write-Error "JSON file not found: $jsonPath"
            throw "JSON file not found"
        }
    }
}

# Export the class so it can be imported
Export-ModuleMember -Function * -Cmdlet * -Variable * -Alias *
