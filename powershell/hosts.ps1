#Requires -RunAsAdministrator

class HostsFile {
    [string]$HostsPath
    [string]$BackupPath
    [string]$LogPath
    
    # Constructor
    HostsFile() {
        $this.HostsPath = "$env:windir\System32\drivers\etc\hosts"
        $this.BackupPath = "$($this.HostsPath).bak"
        $this.LogPath = "$env:TEMP\HostsFile.log"
        $this.EnsurePsHostsInstalled()
    }
    
    # Constructor with custom paths
    HostsFile([string]$hostsPath, [string]$backupPath, [string]$logPath) {
        $this.HostsPath = $hostsPath
        $this.BackupPath = $backupPath
        $this.LogPath = $logPath
        $this.EnsurePsHostsInstalled()
    }
    
    # Ensure PsHosts module is installed
    [void]EnsurePsHostsInstalled() {
        if (-not (Get-Command "Get-HostEntry" -ErrorAction SilentlyContinue)) {
            try {
                Install-Module PsHosts -Force -ErrorAction Stop
                $this.WriteLog("Installed PsHosts module")
            }
            catch {
                $this.WriteLog("Failed to install PsHosts module: $_", "ERROR")
                throw "PsHosts module installation failed: $_"
            }
        }
    }
    
    # Logging function
    [void]WriteLog([string]$Message) {
        $this.WriteLog($Message, "INFO")
    }
    
    [void]WriteLog([string]$Message, [string]$Level) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        Add-Content -Path $this.LogPath -Value $logEntry
        if ($Level -eq "ERROR") {
            Write-Error $logEntry
        }
        else {
            Write-Host $logEntry
        }
    }
    
    # Backup hosts file
    [void]Backup() {
        if (Test-Path $this.HostsPath) {
            Copy-Item -Path $this.HostsPath -Destination $this.BackupPath -Force
            $this.WriteLog("Created backup of hosts file at $($this.BackupPath)")
        }
        else {
            $this.WriteLog("Hosts file not found at $($this.HostsPath)", "ERROR")
            throw "Hosts file not found"
        }
    }
    
    # Backup with custom path
    [void]Backup([string]$customBackupPath) {
        if (Test-Path $this.HostsPath) {
            Copy-Item -Path $this.HostsPath -Destination $customBackupPath -Force
            $this.WriteLog("Created backup of hosts file at $customBackupPath")
        }
        else {
            $this.WriteLog("Hosts file not found at $($this.HostsPath)", "ERROR")
            throw "Hosts file not found"
        }
    }
    
    # Restore from backup
    [void]Restore() {
        if (Test-Path $this.BackupPath) {
            Copy-Item -Path $this.BackupPath -Destination $this.HostsPath -Force
            $this.WriteLog("Restored hosts file from backup")
        }
        else {
            $this.WriteLog("Backup file not found at $($this.BackupPath)", "ERROR")
            throw "Backup file not found"
        }
    }
    
    # Restore from custom path
    [void]Restore([string]$customBackupPath) {
        if (Test-Path $customBackupPath) {
            Copy-Item -Path $customBackupPath -Destination $this.HostsPath -Force
            $this.WriteLog("Restored hosts file from $customBackupPath")
        }
        else {
            $this.WriteLog("Backup file not found at $customBackupPath", "ERROR")
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
            $this.WriteLog("Added entry: $ipAddress -> $hostname")
        }
    }
    
    # Add host entry with comment
    [void]AddEntry([string]$ipAddress, [string[]]$hostnames, [string]$comment) {
        foreach ($hostname in $hostnames) {
            Set-HostEntry $hostname $ipAddress -Comment $comment -Force
            $this.WriteLog("Added entry: $ipAddress -> $hostname (Comment: $comment)")
        }
    }
    
    # Remove entries by IP address
    [void]RemoveEntriesByIP([string]$ipAddress) {
        $entries = Get-HostEntry | Where-Object { $_.IPAddress -eq $ipAddress }
        if ($entries) {
            $entries | Remove-HostEntry
            $this.WriteLog("Removed $(@($entries).Count) entry(ies) for IP address: $ipAddress")
        }
        else {
            $this.WriteLog("No entry found for IP address: $ipAddress", "WARN")
        }
    }
    
    # Remove entries by hostname
    [void]RemoveEntriesByHostname([string]$hostname) {
        $entries = Get-HostEntry | Where-Object { $_.HostName -eq $hostname }
        if ($entries) {
            $entries | Remove-HostEntry
            $this.WriteLog("Removed entry for hostname: $hostname")
        }
        else {
            $this.WriteLog("No entry found for hostname: $hostname", "WARN")
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
                    $this.WriteLog("Removed hostname '$hostname' from IP $($entry.IPAddress) (other hostnames remain)")
                }
                else {
                    # Only hostname for this IP, remove the entire entry
                    Remove-HostEntry -HostName $hostname
                    $this.WriteLog("Removed entry for hostname '$hostname' from IP $($entry.IPAddress) (was the only hostname)")
                }
            }
        }
        else {
            $this.WriteLog("No entry found for hostname: $hostname", "WARN")
        }
    }
    
    # Remove entries by comment
    [void]RemoveEntriesByComment([string]$comment) {
        $entries = Get-HostEntry | Where-Object { $_.Comment -match $comment }
        if ($entries) {
            $entries | Remove-HostEntry
            $this.WriteLog("Removed $(@($entries).Count) entries with comment matching: $comment")
        }
        else {
            $this.WriteLog("No entries found with comment matching: $comment", "WARN")
        }
    }
    
    # Remove entries NOT matching a comment (keep only specific entries)
    [void]KeepOnlyEntriesByComment([string]$comment) {
        $entries = Get-HostEntry | Where-Object { -not ($_.Comment -match $comment) }
        if ($entries) {
            $entries | Remove-HostEntry
            $this.WriteLog("Removed $(@($entries).Count) entries NOT matching comment: $comment")
        }
    }
    
    # Clear all entries
    [void]ClearAll() {
        $entries = Get-HostEntry
        if ($entries) {
            $entries | Remove-HostEntry
            $this.WriteLog("Cleared all host entries")
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
        $this.WriteLog("Exported hosts file to JSON: $outputPath")
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
            $this.WriteLog("Imported $(@($entries).Count) entries from JSON: $jsonPath")
        }
        else {
            $this.WriteLog("JSON file not found: $jsonPath", "ERROR")
            throw "JSON file not found"
        }
    }
}

# Export the class so it can be imported
Export-ModuleMember -Function * -Cmdlet * -Variable * -Alias *
