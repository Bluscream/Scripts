# WNetWatcher Network Report Generator
# Generates CSV files per network interface, combines them, and creates a Bootstrap HTML table

param(
    [string]$OutputDir = ".\temp",
    [string]$OutputFileCSV = ".\network-devices.csv",
    [string]$OutputFileHTML = ".\network-report.html"
)

# Function to convert IP address from integer to dotted decimal
function Convert-IPAddress {
    param([int]$IPInt)
    
    if ($IPInt -lt 0) {
        $IPInt = [uint32]::MaxValue + $IPInt + 1
    }
    
    $bytes = [BitConverter]::GetBytes($IPInt)
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    
    return ($bytes -join '.')
}

# Function to get network interfaces
function Get-NetworkInterfaces {
    try {
        $interfaces = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.ConnectionState -ne "Disconnected" -and $_.InterfaceDescription -notlike "*Loopback*" -and $_.InterfaceDescription -notlike "*XBOX*" -and $_.InterfaceDescription -notlike "*Hyper-V*" }
        return $interfaces
    }
    catch {
        Write-Warning "Could not enumerate network interfaces. Will use default interface."
        return @()
    }
}

# Function to create a temporary CFG file for a specific interface
function New-TemporaryCFG {
    param(
        [string]$InterfaceGuid,
        [string]$OutputDir
    )
    
    $cfgLines = @(
        "[General]",
        "ShowGridLines=0",
        "SaveFilterIndex=0",
        "ShowInfoTip=1",
        "BlackBackground=0",
        "MarkOddEvenRows=0",
        "UseNetworkAdapter=1",
        "NetworkAdapter=$InterfaceGuid",
        "BackgroundScan=0",
        "BeepOnNewDevice=0",
        "BeepOnDeviceDisconnect=0",
        "TrayIcon=0",
        "TrayBalloonOnNewDevice=0",
        "TrayBalloonOnDeviceDisconnect=0",
        "ScanIPv6Addresses=1",
        "UseIPAddressesRange=0",
        "ScanOnProgramStart=0",
        "AutoCopyDeviceNameToUserText=1",
        "MacAddressFormat=1",
        "StartAsHidden=1",
        "CustomNewDeviceSound=0",
        "CustomNewDeviceSoundFile=",
        "CustomDisconnectedDeviceSound=0",
        "CustomDisconnectedDeviceSoundFile=",
        "AlertOnlyForFirstDetection=0",
        "ClearARPCache=1",
        "UseNewDeviceExecuteCommand=0",
        "NewDeviceExecuteCommand=",
        "UseDisconnectedDeviceExecuteCommand=0",
        "DisconnectedDeviceExecuteCommand=",
        "BackgroundScanInterval=900",
        "ShowInactiveDevices=0",
        "ShowPrevDevices=0",
        "AlwaysOnTop=0",
        "AutoShowAdvancedOptions=0",
        "AutoSizeColumnsOnScan=1",
        "AutoSortOnEveryScan=1"
    )
    
    $cfgContent = $cfgLines -join "`n"
    
    $cfgFile = Join-Path $OutputDir "WNetWatcher.cfg"
    $cfgContent | Out-File -FilePath $cfgFile -Encoding UTF8
    return $cfgFile
}

# Function to run WNetWatcher for a specific interface (synchronous version)
function Invoke-WNetWatcher {
    param(
        [string]$InterfaceGuid,
        [string]$OutputFile,
        [string]$OutputDir
    )
    
    $cfgFile = $null
    
    try {
        $arguments = @(
            "/scomma", "`"$OutputFile`""
        )
        
        if ($InterfaceGuid) {
            # Create temporary CFG file for this interface
            $cfgFile = New-TemporaryCFG -InterfaceGuid $InterfaceGuid -OutputDir $OutputDir
            $arguments += "/cfg", "`"$cfgFile`""
            Write-Host "Created temporary CFG file: $cfgFile" -ForegroundColor Green
        }
        
        $process = Start-Process -FilePath "WNetWatcher.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0 -and (Test-Path $OutputFile)) {
            return $true
        }
        else {
            Write-Warning "WNetWatcher failed for interface $InterfaceGuid. Exit code: $($process.ExitCode)"
            return $false
        }
    }
    catch {
        Write-Error "Error running WNetWatcher: $_"
        return $false
    }
    finally {
        # Clean up temporary CFG file
        if ($cfgFile -and (Test-Path $cfgFile)) {
            Remove-Item -Path $cfgFile -Force
            Write-Host "Cleaned up temporary CFG file: $cfgFile" -ForegroundColor Green
        }
    }
}

# Function to run WNetWatcher asynchronously using PowerShell jobs
function Start-WNetWatcherJob {
    param(
        [string]$InterfaceGuid,
        [string]$OutputFile,
        [string]$OutputDir,
        [string]$InterfaceName
    )
    
    $jobScript = {
        param(
            [string]$InterfaceGuid,
            [string]$OutputFile,
            [string]$OutputDir,
            [string]$InterfaceName
        )
        
        # Function to create a temporary CFG file for a specific interface (redefined for job scope)
        function New-TemporaryCFG {
            param(
                [string]$InterfaceGuid,
                [string]$OutputDir
            )
            
            $cfgLines = @(
                "[General]",
                "ShowGridLines=0",
                "SaveFilterIndex=0",
                "ShowInfoTip=1",
                "BlackBackground=0",
                "MarkOddEvenRows=0",
                "UseNetworkAdapter=1",
                "NetworkAdapter=$InterfaceGuid",
                "BackgroundScan=0",
                "BeepOnNewDevice=0",
                "BeepOnDeviceDisconnect=0",
                "TrayIcon=0",
                "TrayBalloonOnNewDevice=0",
                "TrayBalloonOnDeviceDisconnect=0",
                "ScanIPv6Addresses=1",
                "UseIPAddressesRange=0",
                "ScanOnProgramStart=0",
                "AutoCopyDeviceNameToUserText=1",
                "MacAddressFormat=1",
                "StartAsHidden=1",
                "CustomNewDeviceSound=0",
                "CustomNewDeviceSoundFile=",
                "CustomDisconnectedDeviceSound=0",
                "CustomDisconnectedDeviceSoundFile=",
                "AlertOnlyForFirstDetection=0",
                "ClearARPCache=1",
                "UseNewDeviceExecuteCommand=0",
                "NewDeviceExecuteCommand=",
                "UseDisconnectedDeviceExecuteCommand=0",
                "DisconnectedDeviceExecuteCommand=",
                "BackgroundScanInterval=900",
                "ShowInactiveDevices=0",
                "ShowPrevDevices=0",
                "AlwaysOnTop=0",
                "AutoShowAdvancedOptions=0",
                "AutoSizeColumnsOnScan=1",
                "AutoSortOnEveryScan=1"
            )
            
            $cfgContent = $cfgLines -join "`n"
            
            $cfgFile = Join-Path $OutputDir "WNetWatcher-$InterfaceName.cfg"
            $cfgContent | Out-File -FilePath $cfgFile -Encoding UTF8
            return $cfgFile
        }
        
        $cfgFile = $null
        
        try {
            $arguments = @(
                "/scomma", "`"$OutputFile`""
            )
            
            if ($InterfaceGuid) {
                # Create temporary CFG file for this interface
                $cfgFile = New-TemporaryCFG -InterfaceGuid $InterfaceGuid -OutputDir $OutputDir -InterfaceName $InterfaceName
                $arguments += "/cfg", "`"$cfgFile`""
            }
            
            $process = Start-Process -FilePath "WNetWatcher.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
            
            $result = @{
                Success       = ($process.ExitCode -eq 0 -and (Test-Path $OutputFile))
                ExitCode      = $process.ExitCode
                OutputFile    = $OutputFile
                InterfaceName = $InterfaceName
                InterfaceGuid = $InterfaceGuid
            }
            
            return $result
        }
        catch {
            return @{
                Success       = $false
                Error         = $_.Exception.Message
                OutputFile    = $OutputFile
                InterfaceName = $InterfaceName
                InterfaceGuid = $InterfaceGuid
            }
        }
        finally {
            # Clean up temporary CFG file
            if ($cfgFile -and (Test-Path $cfgFile)) {
                Remove-Item -Path $cfgFile -Force
            }
        }
    }
    
    return Start-Job -ScriptBlock $jobScript -ArgumentList $InterfaceGuid, $OutputFile, $OutputDir, $InterfaceName
}

# Function to create Bootstrap HTML table
function Convert-CSVToBootstrapHTML {
    param(
        [string]$CSVFile,
        [string]$OutputFile
    )
    
    try {
        $csvData = Import-Csv $CSVFile
        
        if ($csvData.Count -eq 0) {
            Write-Warning "No data found in CSV file: $CSVFile"
            return
        }
        
        # Get column headers
        $headers = $csvData[0].PSObject.Properties.Name
        
        # Create HTML content
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Network Devices Report</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.0/font/bootstrap-icons.css" rel="stylesheet">
    <style>
        .table-responsive { max-height: 80vh; }
        .device-info { font-size: 0.9em; }
        .mac-address { font-family: 'Courier New', monospace; }
        .ip-address { font-family: 'Courier New', monospace; }
        .status-active { color: #198754; }
        .status-inactive { color: #dc3545; }
        .detection-count { font-weight: bold; }
        .company-info { font-style: italic; }
        .interface-info { font-weight: bold; }
    </style>
</head>
<body>
    <div class="container-fluid mt-3">
        <div class="row">
            <div class="col-12">
                <h1 class="mb-4">
                    <i class="bi bi-wifi"></i> Network Devices Report
                    <small class="text-muted">Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</small>
                </h1>
                
                <div class="card">
                    <div class="card-header">
                        <h5 class="mb-0">
                            <i class="bi bi-list-ul"></i> 
                            Network Devices ($($csvData.Count) devices found)
                        </h5>
                    </div>
                    <div class="card-body p-0">
                        <div class="table-responsive">
                            <table class="table table-striped table-hover mb-0">
                                <thead class="table-dark sticky-top">
                                    <tr>
"@

        # Add table headers
        foreach ($header in $headers) {
            $displayName = switch ($header) {
                'IP Address' { 'IP Address' }
                'Device Name' { 'Device Name' }
                'MAC Address' { 'MAC Address' }
                'Network Adapter Company' { 'Company' }
                'Device Information' { 'Info' }
                'User Text' { 'User Text' }
                'Interface' { 'Interface' }
                'First Detected On' { 'First Seen' }
                'Last Detected On' { 'Last Seen' }
                default { $header }
            }
            
            $html += "`n                                        <th scope=`"col`">$displayName</th>"
        }
        
        $html += @"
                                    </tr>
                                </thead>
                                <tbody>
"@

        # Add table rows
        foreach ($row in $csvData) {
            $html += "`n                                    <tr>"
            
            foreach ($header in $headers) {
                $value = $row.$header
                $cellClass = ""
                $cellContent = ""
                
                switch ($header) {
                    'IP Address' {
                        $cellClass = "ip-address"
                        $cellContent = $value
                    }
                    'MAC Address' {
                        $cellClass = "mac-address"
                        $cellContent = $value
                    }
                    'Network Adapter Company' {
                        $cellClass = "company-info"
                        $cellContent = $value
                    }
                    'Device Information' {
                        if ($value -eq "Your Computer") {
                            $cellContent = "<span class=`"badge bg-primary`">$value</span>"
                        }
                        elseif ($value -eq "Your Router") {
                            $cellContent = "<span class=`"badge bg-success`">$value</span>"
                        }
                        else {
                            $cellContent = $value
                        }
                    }
                    'Interface' {
                        $cellClass = "interface-info"
                        $cellContent = "<span class=`"badge bg-info`">$value</span>"
                    }
                    default {
                        $cellContent = $value
                    }
                }
                
                $html += "`n                                        <td class=`"$cellClass`">$cellContent</td>"
            }
            
            $html += "`n                                    </tr>"
        }
        
        $html += @"
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
                
                <div class="mt-3">
                    <small class="text-muted">
                        <i class="bi bi-info-circle"></i> 
                        Report generated by WNetWatcher Network Report Generator
                    </small>
                </div>
            </div>
        </div>
    </div>
    
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
"@

        # Write HTML to file
        $html | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-Host "HTML report generated: $OutputFile" -ForegroundColor Green
        
    }
    catch {
        Write-Error "Error converting CSV to HTML: $_"
    }
}

# Main execution
Write-Host "WNetWatcher Network Report Generator" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Check if WNetWatcher.exe is available in PATH
try {
    $null = Get-Command "WNetWatcher.exe" -ErrorAction Stop
    Write-Host "Found WNetWatcher.exe in PATH" -ForegroundColor Green
}
catch {
    Write-Error "WNetWatcher.exe not found in PATH"
    Write-Host "Please ensure WNetWatcher.exe is installed and available in your system PATH" -ForegroundColor Yellow
    Write-Host "You can download it from: https://www.nirsoft.net/utils/wireless_network_watcher.html" -ForegroundColor Yellow
    exit 1
}

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "Created output directory: $OutputDir" -ForegroundColor Green
}

# Get network interfaces
Write-Host "`nEnumerating network interfaces..." -ForegroundColor Yellow
$interfaces = Get-NetworkInterfaces

if ($interfaces.Count -eq 0) {
    Write-Host "No network interfaces found. Running WNetWatcher with default settings..." -ForegroundColor Yellow
    
    $tempCsvFile = Join-Path $OutputDir "network-devices.csv"
    if (Invoke-WNetWatcher -OutputFile $tempCsvFile -OutputDir $OutputDir) {
        Write-Host "Generated CSV file: $tempCsvFile" -ForegroundColor Green
        $csvFile = $tempCsvFile
    }
    else {
        Write-Error "Failed to generate CSV file"
        exit 1
    }
}
else {
    Write-Host "Found $($interfaces.Count) network interface(s)" -ForegroundColor Green
    
    # Start WNetWatcher jobs for all interfaces asynchronously
    Write-Host "`nStarting WNetWatcher scans for all interfaces in parallel..." -ForegroundColor Yellow
    $jobs = @()
    $interfaceJobs = @{}
    
    foreach ($interface in $interfaces) {
        Write-Host "Starting scan for interface: $($interface.Name) ($($interface.InterfaceDescription))" -ForegroundColor Cyan
        
        $csvFile = Join-Path $OutputDir "network-devices-$($interface.Name).csv"
        $job = Start-WNetWatcherJob -InterfaceGuid $interface.InterfaceGuid -OutputFile $csvFile -OutputDir $OutputDir -InterfaceName $interface.Name
        
        $jobs += $job
        $interfaceJobs[$job.Id] = @{
            Interface  = $interface
            OutputFile = $csvFile
            Job        = $job
        }
    }
    
    # Wait for all jobs to complete with progress monitoring
    Write-Host "`nWaiting for all WNetWatcher scans to complete..." -ForegroundColor Yellow
    $completedJobs = 0
    $totalJobs = $jobs.Count
    
    while ($jobs | Where-Object { $_.State -eq 'Running' }) {
        $runningJobs = ($jobs | Where-Object { $_.State -eq 'Running' }).Count
        $completedJobs = $totalJobs - $runningJobs
        
        Write-Progress -Activity "WNetWatcher Network Scanning" -Status "Scanning network interfaces" -CurrentOperation "Completed: $completedJobs/$totalJobs" -PercentComplete (($completedJobs / $totalJobs) * 100)
        
        Start-Sleep -Seconds 2
    }
    
    Write-Progress -Activity "WNetWatcher Network Scanning" -Completed
    
    # Collect results from all jobs
    Write-Host "`nCollecting results from all scans..." -ForegroundColor Yellow
    $csvFiles = @()
    $successCount = 0
    $failureCount = 0
    
    foreach ($jobId in $interfaceJobs.Keys) {
        $interfaceJob = $interfaceJobs[$jobId]
        $job = $interfaceJob.Job
        $interface = $interfaceJob.Interface
        $outputFile = $interfaceJob.OutputFile
        
        try {
            $result = Receive-Job -Job $job -Wait
            
            if ($result.Success) {
                Write-Host "✓ Successfully generated CSV for interface: $($interface.Name)" -ForegroundColor Green
                $csvFiles += $outputFile
                $successCount++
            }
            else {
                if ($result.Error) {
                    Write-Warning "✗ Failed to generate CSV for interface $($interface.Name): $($result.Error)"
                }
                else {
                    Write-Warning "✗ Failed to generate CSV for interface $($interface.Name). Exit code: $($result.ExitCode)"
                }
                $failureCount++
            }
        }
        catch {
            Write-Error "Error retrieving results for interface $($interface.Name): $_"
            $failureCount++
        }
        finally {
            Remove-Job -Job $job -Force
        }
    }
    
    Write-Host "`nScan Summary:" -ForegroundColor Cyan
    Write-Host "  ✓ Successful scans: $successCount" -ForegroundColor Green
    Write-Host "  ✗ Failed scans: $failureCount" -ForegroundColor Red
    
    if ($csvFiles.Count -eq 0) {
        Write-Error "No CSV files were generated successfully"
        exit 1
    }
    
    # Combine all CSV files
    Write-Host "`nCombining CSV files..." -ForegroundColor Yellow
    
    $allData = @()
    foreach ($csvFile in $csvFiles) {
        if (Test-Path $csvFile) {
            $data = Import-Csv $csvFile
            
            # Extract interface name from filename (e.g., "network-devices-Wi-Fi.csv" -> "Wi-Fi")
            $interfaceName = [System.IO.Path]::GetFileNameWithoutExtension($csvFile) -replace '^network-devices-', ''
            
            # Add interface column to each row
            $data | ForEach-Object { 
                $_ | Add-Member -NotePropertyName "Interface" -NotePropertyValue $interfaceName -Force
            }
            
            $allData += $data
            Write-Host "Added $($data.Count) devices from $csvFile (Interface: $interfaceName)" -ForegroundColor Green
        }
    }
    
    if ($allData.Count -gt 0) {
        # Remove duplicates based on IP Address and sort by IP Address (numeric)
        $uniqueData = $allData | Group-Object "IP Address" | ForEach-Object { $_.Group[0] } | Sort-Object { 
            [System.Net.IPAddress]::Parse($_.'IP Address').GetAddressBytes() | ForEach-Object { $_.ToString('D3') } | Join-String -Separator '.'
        }
        Write-Host "Removed duplicate IP addresses and sorted. Total unique devices: $($uniqueData.Count)" -ForegroundColor Green
        
        # Remove Detection Count and Active columns
        $filteredData = $uniqueData | Select-Object -Property * -ExcludeProperty "Detection Count", "Active"
        Write-Host "Filtered out Detection Count and Active columns" -ForegroundColor Green
        
        # Export combined data to final CSV file
        $filteredData | Export-Csv -Path $OutputFileCSV -NoTypeInformation
        Write-Host "Combined CSV file created: $OutputFileCSV" -ForegroundColor Green
        
        # Use final CSV file for HTML generation
        $csvFile = $OutputFileCSV
    }
    else {
        Write-Error "No data found in any CSV files"
        exit 1
    }
}

# Convert to HTML
Write-Host "`nConverting to Bootstrap HTML table..." -ForegroundColor Yellow
Convert-CSVToBootstrapHTML -CSVFile $csvFile -OutputFile $OutputFileHTML

# Clean up temporary files (but keep the final CSV and HTML files)
Write-Host "`nCleaning up temporary files..." -ForegroundColor Yellow
if (Test-Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
    Write-Host "Temporary directory removed: $OutputDir" -ForegroundColor Green
}

Write-Host "`nReport generation completed successfully!" -ForegroundColor Green
Write-Host "CSV file: $OutputFileCSV" -ForegroundColor Cyan
Write-Host "HTML report: $OutputFileHTML" -ForegroundColor Cyan

# Open the HTML file in default browser
if (Test-Path $OutputFileHTML) {
    Write-Host "`nOpening report in default browser..." -ForegroundColor Yellow
    Start-Process $OutputFileHTML
}
