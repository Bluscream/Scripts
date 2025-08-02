#Requires -Version 5.1

<#
.SYNOPSIS
    Converts Windows Scheduled Tasks to RestartOnCrash INI format
    
.DESCRIPTION
    This script extracts all scheduled tasks for each user on the computer and converts them
    into an INI file format compatible with RestartOnCrash application.
    
.PARAMETER OutputPath
    The path where the INI file will be saved. Defaults to current directory.
    

    
 .PARAMETER NoElevate
     Skip automatic elevation to administrator privileges.
     
 .PARAMETER Triggers
     Filter tasks to only include those with specified trigger types.
     Valid values: BootTrigger, LogonTrigger, TimeTrigger, CalendarTrigger, 
     IdleTrigger, EventTrigger, RegistrationTrigger, SessionStateChangeTrigger
     
 .PARAMETER EnabledOnly
     Only process tasks that are enabled (skip disabled tasks).
     
 .PARAMETER DisableTasks
     Stop and disable the scheduled tasks after successful conversion (requires administrator privileges).
     
 .PARAMETER Merge
     Merge new entries into existing INI file, only adding entries where FileName doesn't already exist.
     
 .PARAMETER WriteExtra
     Include extra fields in the INI output (Triggers and GeneratorCommand). By default, these are excluded for cleaner output.
     
 .PARAMETER Ignore
     Array of wildcard patterns to ignore tasks based on their task path (e.g., \Startup\Microsoft\Task). Useful for excluding system tasks.
     Example: -Ignore "*\Microsoft\*","*\OneDrive\*","*\Windows\*"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -OutputPath "C:\temp\restart-on-crash.ini"
     

     
 .EXAMPLE
     .\tasks-to-roc.ps1 -NoElevate -OutputPath "C:\temp\restart-on-crash.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Triggers "BootTrigger","LogonTrigger" -OutputPath "C:\temp\boot-logon-tasks.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -EnabledOnly -OutputPath "C:\temp\enabled-tasks.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Triggers "BootTrigger","LogonTrigger" -EnabledOnly -OutputPath "C:\temp\enabled-boot-logon.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -DisableTasks -OutputPath "C:\temp\restart-on-crash.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Triggers "BootTrigger","LogonTrigger" -DisableTasks -OutputPath "C:\temp\boot-logon-disabled.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Merge -OutputPath "C:\temp\existing-config.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -WriteExtra -OutputPath "C:\temp\restart-on-crash-with-extras.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Ignore "*\Microsoft\*","*\OneDrive\*" -OutputPath "C:\temp\filtered-tasks.ini"
#>

param(
    [string]$OutputPath = ".\restart-on-crash.ini",
    [switch]$NoElevate,
    [string[]]$Triggers = @(),
    [switch]$EnabledOnly,
    [switch]$DisableTasks,
    [switch]$Merge,
    [switch]$WriteExtra,
    [string[]]$Ignore = @()
)

# Self-elevation logic
if (-not $NoElevate -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    $elevationReason = if ($DisableTasks) { "disable scheduled tasks" } else { "access all scheduled tasks" }
    Write-Host "This script requires administrator privileges to $elevationReason." -ForegroundColor Yellow
    Write-Host "Attempting to elevate privileges..." -ForegroundColor Yellow
    
    try {
        $arguments = $PSBoundParameters.GetEnumerator() | ForEach-Object {
            if ($_.Key -eq "NoElevate") { return }
            if ($_.Value -is [switch]) {
                if ($_.Value.IsPresent) { "-$($_.Key)" }
            }
            else {
                "-$($_.Key)", "`"$($_.Value)`""
            }
        }
        
        Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"", $arguments -Verb RunAs -Wait
        exit
    }
    catch {
        Write-Warning "Could not elevate privileges automatically. Please run as Administrator manually."
        Write-Host "Continuing with limited access..." -ForegroundColor Yellow
    }
}

# =============================================================================
# CONFIGURATION SECTION - Modify these settings as needed
# =============================================================================

# General settings for RestartOnCrash
$Script:GeneralSettings = @{
    RestartGracePeriod               = 30
    Autorun                          = 0
    StartMinimized                   = 1
    LogToFile                        = 1
    LogFileName                      = "$env:TEMP\RestartOnCrash.log"
    CheckForUpdates                  = 1
    MinimizeOnClose                  = 1
    ManualRestartConfirmationEnabled = 1
}

# Default settings for each application entry
$Script:DefaultAppSettings = @{
    WindowTitle          = ""
    Enabled              = 1
    CommandEnabled       = 1
    CrashNotResponding   = 1
    CrashNotRunning      = 0
    KillIfHanged         = 1
    CloseProblemReporter = 1
    DelayEnabled         = 1
    CrashDelay           = 60
    Triggers             = ""
}

# Application-specific overrides (optional)
# Add custom settings for specific applications here
$Script:AppOverrides = @{
    # Example: Override settings for specific applications
    # "C:\Program Files\Example\app.exe" = @{
    #     CrashDelay = 120
    #     CrashNotRunning = 1
    # }
}

# =============================================================================

Set-Variable -Name "commandLine" -Value "$($MyInvocation.Line -replace ';', ' ' -replace '"', "'")" -Scope Global
Write-Host "Script Command Line: $commandLine"

# Function to show application summary
function Show-ApplicationSummary {
    param([array]$Applications)
    
    if ($Applications.Count -gt 0) {
        Write-Host "`nApplications found:" -ForegroundColor Magenta
        for ($i = 0; $i -lt $Applications.Count; $i++) {
            Write-Host "  [$i] $($Applications[$i].FileName)" -ForegroundColor White
        }
    }
    else {
        Write-Host "No applications found." -ForegroundColor Yellow
    }
}

# Function to stop and disable scheduled tasks
function Stop-AndDisable-ScheduledTasks {
    param([array]$TaskObjects)
    
    Write-Host "`nStopping and disabling scheduled tasks..." -ForegroundColor Yellow
    
    $stoppedCount = 0
    $disabledCount = 0
    $failedCount = 0
    
    foreach ($task in $TaskObjects) {
        try {
            # Get the task name from the file path
            $taskName = $task.TaskName
            
            Write-Host "  Processing: $taskName" -ForegroundColor Gray
            
            # First, try to stop the task if it's running
            try {
                $runningTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($runningTask -and $runningTask.State -eq "Running") {
                    Write-Host "    Stopping running task..." -ForegroundColor Yellow
                    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    Write-Host "    Stopped: $taskName" -ForegroundColor Green
                    $stoppedCount++
                }
                else {
                    Write-Host "    Task not running, skipping stop" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "    Warning: Could not stop task - $($_.Exception.Message)" -ForegroundColor Yellow
            }
            
            # Then disable the task
            try {
                Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop
                Write-Host "    Disabled: $taskName" -ForegroundColor Green
                $disabledCount++
            }
            catch {
                Write-Host "    Failed to disable: $taskName - $($_.Exception.Message)" -ForegroundColor Red
                $failedCount++
            }
            
        }
        catch {
            Write-Host "  Error processing: $($task.TaskName) - $($_.Exception.Message)" -ForegroundColor Red
            $failedCount++
        }
    }
    
    Write-Host "`nTask processing summary:" -ForegroundColor Yellow
    Write-Host "  Successfully stopped: $stoppedCount" -ForegroundColor Green
    Write-Host "  Successfully disabled: $disabledCount" -ForegroundColor Green
    Write-Host "  Failed to process: $failedCount" -ForegroundColor Red
    
    return @{
        StoppedCount  = $stoppedCount
        DisabledCount = $disabledCount
        FailedCount   = $failedCount
    }
}

# Function to get working directory from executable path
function Get-WorkingDirectory {
    param([string]$ExecutablePath)
    
    if ([System.IO.File]::Exists($ExecutablePath)) {
        return [System.IO.Path]::GetDirectoryName($ExecutablePath)
    }
    return ""
}



# Function to extract executable path and arguments from XML task
function Get-ExecutablePathAndArgsFromXml {
    param([object]$Xml)
    
    $executablePath = $null
    $arguments = $null
    
    # Look for executable and arguments in various possible locations
    if ($Xml.Task.Actions.Exec.Command) {
        $command = $Xml.Task.Actions.Exec.Command
        $args = $Xml.Task.Actions.Exec.Arguments
        
        # Remove any existing quotes from the XML
        $executablePath = $command -replace '^"|"$', ''
        
        # Get arguments if present
        if ($args) {
            $arguments = $args
        }
    }
    elseif ($Xml.Task.Actions.Exec.WorkingDirectory) {
        # Sometimes the command is in the working directory
        $workingDir = $Xml.Task.Actions.Exec.WorkingDirectory
        if ($workingDir -and (Test-Path $workingDir)) {
            $exeFiles = Get-ChildItem -Path $workingDir -Filter "*.exe" -ErrorAction SilentlyContinue
            if ($exeFiles.Count -eq 1) {
                $executablePath = $exeFiles[0].FullName
                # No arguments in this case
            }
        }
    }
    
    return @{
        ExecutablePath = $executablePath
        Arguments      = $arguments
    }
}

# Function to extract triggers from XML task
function Get-TriggersFromXml {
    param([object]$Xml)
    
    $taskTriggers = @()
    
    if ($Xml.Task.Triggers) {
        foreach ($trigger in $Xml.Task.Triggers.ChildNodes) {
            $triggerType = $trigger.LocalName
            $triggerInfo = ""
            
            switch ($triggerType) {
                "BootTrigger" { $triggerInfo = "Boot" }
                "LogonTrigger" { $triggerInfo = "Logon" }
                "TimeTrigger" { $triggerInfo = "Time" }
                "CalendarTrigger" { $triggerInfo = "Calendar" }
                "IdleTrigger" { $triggerInfo = "Idle" }
                "EventTrigger" { $triggerInfo = "Event" }
                "RegistrationTrigger" { $triggerInfo = "Registration" }
                "SessionStateChangeTrigger" { $triggerInfo = "SessionStateChange" }
                default { $triggerInfo = $triggerType }
            }
            
            if ($triggerInfo) {
                $taskTriggers += $triggerInfo
            }
        }
    }
    
    return $taskTriggers
}

# Function to check if task has specified triggers
function Test-TaskHasSpecifiedTriggers {
    param(
        [object]$Xml,
        [string[]]$SpecifiedTriggers
    )
    
    # If no triggers specified, include all tasks
    if ($SpecifiedTriggers.Count -eq 0) {
        return $true
    }
    
    if ($Xml.Task.Triggers) {
        foreach ($trigger in $Xml.Task.Triggers.ChildNodes) {
            $triggerType = $trigger.LocalName
            
            # Check if this trigger type is in the specified triggers
            if ($SpecifiedTriggers -contains $triggerType) {
                return $true
            }
        }
    }
    
    return $false
}

# Function to check if task should be ignored based on task path
function Test-TaskShouldBeIgnored {
    param(
        [string]$TaskPath,
        [string[]]$IgnorePatterns
    )
    
    # If no ignore patterns specified, don't ignore anything
    if ($IgnorePatterns.Count -eq 0) {
        return $false
    }
    
    # Check if task path matches any ignore pattern
    foreach ($pattern in $IgnorePatterns) {
        if ($TaskPath -like $pattern) {
            return $true
        }
    }
    
    return $false
}

# Function to check if task is enabled
function Test-TaskIsEnabled {
    param([object]$Xml)
    
    # Check if the task has an enabled state
    if ($Xml.Task.Settings.Enabled) {
        return $Xml.Task.Settings.Enabled -eq "true"
    }
    
    # If no explicit enabled state, assume it's enabled
    return $true
}

# Function to format path with quotes if needed
function Format-PathWithQuotes {
    param([string]$Path)
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    
    # Remove any existing quotes first
    $cleanPath = $Path -replace '^"|"$', ''
    
    if ($cleanPath -match '\s') {
        return "`"$cleanPath`""
    }
    else {
        return $cleanPath
    }
}

# Function to create application entry from executable path and arguments
function New-ApplicationEntry {
    param(
        [string]$ExecutablePath,
        [string]$WorkingDirectory,
        [string]$Arguments = "",
        [string]$Triggers = ""
    )
    
    # Create application entry with default settings
    $app = $Script:DefaultAppSettings.Clone()
    
    # Ensure consistent quote formatting for FileName (just the executable)
    $app.FileName = Format-PathWithQuotes -Path $ExecutablePath
    
    # Build the Command with arguments if present
    if ($Arguments) {
        $app.Command = "$(Format-PathWithQuotes -Path $ExecutablePath) $Arguments"
    }
    else {
        $app.Command = Format-PathWithQuotes -Path $ExecutablePath
    }
    
    $app.WorkingDirectory = Format-PathWithQuotes -Path $WorkingDirectory
    $app.Triggers = $Triggers
    
    # Apply application-specific overrides if they exist
    if ($Script:AppOverrides.ContainsKey($ExecutablePath)) {
        foreach ($overrideKey in $Script:AppOverrides[$ExecutablePath].Keys) {
            $app[$overrideKey] = $Script:AppOverrides[$ExecutablePath][$overrideKey]
        }
    }
    
    return $app
}

# Function to scan task directories
function Get-TaskXmlFiles {
    param([array]$TaskPaths)
    
    $taskXmlFiles = @()
    
    foreach ($taskPath in $TaskPaths) {
        if (Test-Path $taskPath) {
            # Windows scheduled tasks are stored as files without extensions
            $taskFiles = Get-ChildItem -Path $taskPath -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq "" }
            $taskXmlFiles += $taskFiles
            Write-Host "Found $($taskFiles.Count) tasks in $taskPath" -ForegroundColor Gray
        }
    }
    
    return $taskXmlFiles
}

# Function to process task XML file and return task object
function Process-TaskXmlFile {
    param(
        [System.IO.FileInfo]$XmlFile,
        [int]$ProcessedCount,
        [string[]]$SpecifiedTriggers = @(),
        [bool]$EnabledOnly = $false,
        [string[]]$IgnorePatterns = @()
    )
    
    try {
        # Parse the XML file
        $xmlContent = Get-Content $XmlFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $xmlContent) { return $null }
        
        # Create XML object
        $xml = [xml]$xmlContent
        
        # Check if task has specified triggers (if any specified)
        if (-not (Test-TaskHasSpecifiedTriggers -Xml $xml -SpecifiedTriggers $SpecifiedTriggers)) {
            return $null
        }
        
        # Check if task is enabled (if EnabledOnly is specified)
        if ($EnabledOnly -and -not (Test-TaskIsEnabled -Xml $xml)) {
            return $null
        }
        
        # Extract executable path and arguments from the task
        $execInfo = Get-ExecutablePathAndArgsFromXml -Xml $xml
        $executablePath = $execInfo.ExecutablePath
        $arguments = $execInfo.Arguments
        
        # Debug: Show first few tasks
        if ($ProcessedCount -le 10) {
            Write-Host "Task: $($XmlFile.Name)" -ForegroundColor DarkGray
            Write-Host "  Executable: $executablePath" -ForegroundColor DarkGray
            if ($arguments) {
                Write-Host "  Arguments: $arguments" -ForegroundColor DarkGray
            }
        }
        
        # Skip if no executable found
        if (-not $executablePath) { return $null }
        
        # Extract task path from the XML file path
        $taskPath = $XmlFile.FullName
        # Convert to relative task path format (e.g., \Startup\Microsoft\Task)
        if ($taskPath -like "*\System32\Tasks\*") {
            $taskPath = $taskPath -replace ".*\\System32\\Tasks", ""
        }
        elseif ($taskPath -like "*\Tasks\*") {
            $taskPath = $taskPath -replace ".*\\Tasks", ""
        }
        elseif ($taskPath -like "*\ScheduledJobs\*") {
            $taskPath = $taskPath -replace ".*\\ScheduledJobs", ""
        }
        
        # Check if task should be ignored based on task path
        if (Test-TaskShouldBeIgnored -TaskPath $taskPath -IgnorePatterns $IgnorePatterns) {
            Write-Host "Ignoring task due to pattern match: $taskPath -> $executablePath" -ForegroundColor Yellow
            return $null
        }
        
        # Verify executable exists
        if (-not [System.IO.File]::Exists($executablePath)) { return $null }
        
        # Extract triggers from XML
        $taskTriggers = Get-TriggersFromXml -Xml $xml
        
        # Get working directory
        $workingDir = Get-WorkingDirectory -ExecutablePath $executablePath
        
        # Create and return task object
        return [PSCustomObject]@{
            TaskName         = $XmlFile.Name
            ExecutablePath   = $executablePath
            Arguments        = $arguments
            WorkingDirectory = $workingDir
            TaskTriggers     = $taskTriggers
        }
    }
    catch {
        Write-Warning "Error processing task file '$($XmlFile.Name)': $($_.Exception.Message)"
        return $null
    }
}

# Function to read existing INI file and extract FileNames
function Read-ExistingIniFile {
    param([string]$FilePath)
    
    $existingFileNames = @()
    $existingApplications = @()
    $generalSettings = @{}
    $sectionFileNames = @{} # Hashtable to map section name to FileName

    if (Test-Path $FilePath) {
        try {
            $content = Get-Content $FilePath -ErrorAction Stop
            $currentSection = ""
            $currentApp = @{}
            $currentSectionName = ""

            foreach ($line in $content) {
                $line = $line.Trim()
                
                # Skip empty lines and comments
                if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
                    continue
                }
                
                # Check for section headers
                if ($line.StartsWith('[') -and $line.EndsWith(']')) {
                    # Save previous application if exists
                    if ($currentSection.StartsWith('Application') -and $currentApp.Count -gt 0) {
                        # Fix paths in FileName, Command, and WorkingDirectory
                        foreach ($fixKey in @("FileName", "Command", "WorkingDirectory")) {
                            if ($currentApp.ContainsKey($fixKey)) {
                                $currentApp[$fixKey] = Format-PathWithQuotes $currentApp[$fixKey]
                            }
                        }
                        $existingApplications += $currentApp.Clone()
                        # Save section name and FileName if present
                        if ($currentApp.ContainsKey("FileName")) {
                            $sectionFileNames[$currentSection] = $currentApp["FileName"]
                        }
                        $currentApp = @{}
                    }
                    
                    $currentSection = $line.Substring(1, $line.Length - 2)
                    continue
                }
                
                # Parse key-value pairs
                if ($line.Contains('=')) {
                    $parts = $line.Split('=', 2)
                    $key = $parts[0].Trim()
                    $value = $parts[1].Trim()
                    
                    if ($currentSection -eq "general") {
                        $generalSettings[$key] = $value
                    }
                    elseif ($currentSection.StartsWith('Application')) {
                        # Fix paths in FileName, Command, and WorkingDirectory as we read them
                        if ($key -in @("FileName", "Command", "WorkingDirectory")) {
                            $value = Format-PathWithQuotes $value
                        }
                        $currentApp[$key] = $value
                        
                        # Collect FileNames for duplicate checking
                        if ($key -eq "FileName") {
                            $existingFileNames += $value
                        }
                    }
                }
            }
            
            # Don't forget the last application
            if ($currentSection.StartsWith('Application') -and $currentApp.Count -gt 0) {
                foreach ($fixKey in @("FileName", "Command", "WorkingDirectory")) {
                    if ($currentApp.ContainsKey($fixKey)) {
                        $currentApp[$fixKey] = Format-PathWithQuotes $currentApp[$fixKey]
                    }
                }
                $existingApplications += $currentApp.Clone()
                if ($currentApp.ContainsKey("FileName")) {
                    $sectionFileNames[$currentSection] = $currentApp["FileName"]
                }
            }

            # Print amount of sections and each "SectionName -> FileName" combination
            $sectionCount = $sectionFileNames.Keys.Count
            Write-Host "Found $sectionCount application sections in $FilePath" -ForegroundColor Gray
            if ($Verbose) {
                foreach ($section in $sectionFileNames.Keys) {
                    $fileName = $sectionFileNames[$section]
                    Write-Verbose "$section -> $fileName" -ForegroundColor DarkGray
                }
            }
        }
        catch {
            Write-Warning "Error reading existing INI file: $($_.Exception.Message)"
        }
    }
    
    return @{
        FileNames       = $existingFileNames
        Applications    = $existingApplications
        GeneralSettings = $generalSettings
    }
}

# Function to write INI content
function Write-IniContent {
    param(
        [string]$FilePath,
        [hashtable]$GeneralSettings,
        [array]$Applications,
        [bool]$WriteExtra = $false
    )
    
    $content = @()
    
    # Write general section first (always on top)
    $content += "[general]"
    foreach ($key in $GeneralSettings.Keys | Sort-Object) {
        # Skip GeneratorCommand unless WriteExtra is enabled
        if ($key -eq "GeneratorCommand" -and -not $WriteExtra) { continue }
        
        $value = $GeneralSettings[$key]
        # Don't add extra quotes for GeneratorCommand as it already contains quotes
        if ($key -eq "GeneratorCommand") {
            $content += "$key=""$value"""
        }
        else {
            $content += "$key=$value"
        }
    }
    $content += ""
    
    # Write application sections
    for ($i = 0; $i -lt $Applications.Count; $i++) {
        $app = $Applications[$i]
        $content += "[Application$i]"
        foreach ($key in $app.Keys | Sort-Object) {
            # Skip Triggers field unless WriteExtra is enabled
            if ($key -eq "Triggers" -and -not $WriteExtra) { continue }
            
            $value = $app[$key]
            # The values are already properly formatted with quotes where needed
            $content += "$key=$value"
        }
        $content += ""
    }
    
    # Write to file
    $content | Out-File -FilePath $FilePath -Encoding UTF8
}

# Main script logic
try {
    Write-Host "Extracting scheduled tasks from XML files..." -ForegroundColor Green

    Write-Host "Using output path: $OutputPath"
    
    # Define task paths to scan
    $taskPaths = @(
        "$env:SystemRoot\System32\Tasks",
        "$env:SystemRoot\Tasks"
    )
    
    # Add user-specific task paths
    $userProfiles = Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue
    foreach ($user in $userProfiles) {
        $userTaskPath = "$($user.FullName)\AppData\Local\Microsoft\Windows\PowerShell\ScheduledJobs"
        if (Test-Path $userTaskPath) {
            $taskPaths += $userTaskPath
        }
    }
    
    # Scan for task XML files
    Write-Host "Scanning task directories..." -ForegroundColor Green
    $taskXmlFiles = Get-TaskXmlFiles -TaskPaths $taskPaths
    Write-Host "Found $($taskXmlFiles.Count) total task files" -ForegroundColor Yellow
    
    # Show trigger filtering info if specified
    if ($Triggers.Count -gt 0) {
        Write-Host "Filtering tasks to only include triggers: $($Triggers -join ', ')" -ForegroundColor Cyan
    }
    
    # Show enabled-only filtering info if specified
    if ($EnabledOnly) {
        Write-Host "Filtering tasks to only include enabled tasks" -ForegroundColor Cyan
    }
    
    # Show ignore patterns info if specified
    if ($Ignore.Count -gt 0) {
        Write-Host "Ignoring tasks matching patterns: $($Ignore -join ', ')" -ForegroundColor Cyan
    }
    
    # Show disable tasks warning if specified
    if ($DisableTasks) {
        Write-Host "WARNING: Tasks will be stopped and disabled after successful conversion!" -ForegroundColor Red
        Write-Host "This action cannot be undone automatically. Use with caution." -ForegroundColor Red
    }
    
    # Convert tasks to application format
    $applications = @()
    $processedExecutables = @{}
    $executableTriggers = @{}  # Store triggers for each executable
    
    # Single pass: Process each task XML file and collect all necessary information
    $processedCount = 0
    $validTasks = @()
    
    foreach ($xmlFile in $taskXmlFiles) {
        $processedCount++
        if ($processedCount % 50 -eq 0) {
            Write-Host "Processed $processedCount of $($taskXmlFiles.Count) task files..." -ForegroundColor Gray
        }
        
        $taskObject = Process-TaskXmlFile -XmlFile $xmlFile -ProcessedCount $processedCount -SpecifiedTriggers $Triggers -EnabledOnly $EnabledOnly -IgnorePatterns $Ignore
        
        if ($taskObject) {
            $validTasks += $taskObject
            
            # Store triggers for this executable (for combining later)
            if ($taskObject.TaskTriggers.Count -gt 0) {
                if (-not $executableTriggers.ContainsKey($taskObject.ExecutablePath)) {
                    $executableTriggers[$taskObject.ExecutablePath] = @()
                }
                $executableTriggers[$taskObject.ExecutablePath] += $taskObject.TaskTriggers -join ","
            }
        }
    }
    
    Write-Host "Processing summary:" -ForegroundColor Yellow
    Write-Host "  Total task files processed: $processedCount" -ForegroundColor White
    Write-Host "  Valid tasks found: $($validTasks.Count)" -ForegroundColor White
    
    # Handle merge mode if specified
    $existingData = $null
    $existingFileNames = @()
    if ($Merge) {
        Write-Host "`nMerge mode enabled - checking existing INI file..." -ForegroundColor Cyan
        $existingData = Read-ExistingIniFile -FilePath $OutputPath
        $existingFileNames = $existingData.FileNames
        
        if ($existingData.Applications.Count -gt 0) {
            Write-Host "Found $($existingData.Applications.Count) existing applications" -ForegroundColor Yellow
            Write-Host "Will only add new applications not already present" -ForegroundColor Yellow
            Write-Verbose "Existing FileNames to check against: $($existingFileNames -join ', ')"
        }
    }
    
    # Create application entries from collected task objects
    foreach ($task in $validTasks) {
        # Skip if already processed (duplicate executable)
        if ($processedExecutables.ContainsKey($task.ExecutablePath)) {
            continue
        }
        
        # Skip RestartOnCrash.exe to prevent processing itself (case insensitive)
        if ($task.ExecutablePath -ilike "*RestartOnCrash.exe*") {
            Write-Verbose "Skipping RestartOnCrash.exe: $($task.TaskName) -> $($task.ExecutablePath)"
            continue
        }
        
        # Get combined triggers for this executable
        $combinedTriggers = ""
        if ($executableTriggers.ContainsKey($task.ExecutablePath)) {
            $combinedTriggers = ($executableTriggers[$task.ExecutablePath] | Sort-Object -Unique) -join ", "
        }
        
        # Create application entry
        $app = New-ApplicationEntry -ExecutablePath $task.ExecutablePath -WorkingDirectory $task.WorkingDirectory -Arguments $task.Arguments -Triggers $combinedTriggers
        
        # Check if this application already exists in merge mode
        if ($Merge) {
            Write-Verbose "  Checking for duplicate: '$($app.FileName)'"
            Write-Verbose "  Existing FileNames: $($existingFileNames -join ', ')"
            
            if ($existingFileNames -contains $app.FileName) {
                Write-Verbose "  MATCH FOUND - Skipping: $($task.TaskName) -> $($task.ExecutablePath)"
                continue
            }
            else {
                Write-Verbose "  NO MATCH - Will add: $($task.TaskName) -> $($task.ExecutablePath)"
            }
        }
        
        $applications += $app
        $processedExecutables[$task.ExecutablePath] = $true
        
        Write-Host "Added: $($task.TaskName) -> $($task.ExecutablePath)" -ForegroundColor Cyan
        if ($app.Triggers) {
            Write-Host "  Triggers: $($app.Triggers)" -ForegroundColor DarkCyan
        }
    }
    
    # Use the full command line (including parameters) used to invoke this script for documentation
    $Script:GeneralSettings.GeneratorCommand = $global:commandLine
    Write-Host "GeneratorCommand: $($Script:GeneralSettings.GeneratorCommand)"
    
    # Handle merge mode - combine existing and new applications
    $finalApplications = $applications
    $finalGeneralSettings = $Script:GeneralSettings.Clone()
    
    if ($Merge -and $existingData -and $existingData.Applications.Count -gt 0) {
        Write-Host "`nMerging with existing applications..." -ForegroundColor Cyan
        
        # Use existing general settings but update GeneratorCommand
        $finalGeneralSettings = $existingData.GeneralSettings.Clone()
        $finalGeneralSettings.GeneratorCommand = $Script:GeneralSettings.GeneratorCommand
        
        # Combine existing and new applications
        $finalApplications = $existingData.Applications + $applications
        
        Write-Host "  Existing applications: $($existingData.Applications.Count)" -ForegroundColor Gray
        Write-Host "  New applications: $($applications.Count)" -ForegroundColor Gray
        Write-Host "  Total applications: $($finalApplications.Count)" -ForegroundColor Yellow
        
        if ($applications.Count -gt 0) {
            Write-Verbose "  New applications being added:"
            foreach ($app in $applications) {
                Write-Verbose "    - $($app.FileName)"
            }
        }
    }
    
    # Write INI file using configured general settings
    Write-IniContent -FilePath $OutputPath -GeneralSettings $finalGeneralSettings -Applications $finalApplications -WriteExtra $WriteExtra
    
    if ($Merge) {
        Write-Host "Successfully merged INI file: $OutputPath" -ForegroundColor Green
        Write-Host "New applications added: $($applications.Count)" -ForegroundColor Yellow
        Write-Host "Total applications in file: $($finalApplications.Count)" -ForegroundColor Yellow
    }
    else {
        Write-Host "Successfully created INI file: $OutputPath" -ForegroundColor Green
        Write-Host "Total applications added: $($applications.Count)" -ForegroundColor Yellow
    }
    
    # Stop and disable tasks if requested
    if ($DisableTasks) {
        # Check if we have administrator privileges
        if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            Write-Warning "Cannot stop/disable tasks without administrator privileges. Skipping task processing."
        }
        else {
            $taskResult = Stop-AndDisable-ScheduledTasks -TaskObjects $validTasks
            Write-Host "Task processing completed. Stopped: $($taskResult.StoppedCount), Disabled: $($taskResult.DisabledCount), Failed: $($taskResult.FailedCount)" -ForegroundColor Yellow
        }
    }
    
    # Show summary
    Show-ApplicationSummary -Applications $applications
    
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    # exit 1
}