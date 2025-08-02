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
     Valid values: Boot, Logon, Time, Calendar, Idle, Event, Registration, SessionStateChange
     
 .PARAMETER EnabledOnly
     Only process tasks that are enabled (skip disabled tasks).
     
 .PARAMETER DisableTasks
     Stop and disable the scheduled tasks after successful conversion (requires administrator privileges).
     
 .PARAMETER Merge
     Merge new entries into existing INI file, only adding entries where FileName doesn't already exist.
     
 .PARAMETER WriteExtra
     Include extra fields in the INI output (Triggers and GeneratorCommand). By default, these are excluded for cleaner output.
     
 .PARAMETER Ignore
     Array of patterns to ignore tasks based on their task path. Patterns are automatically wrapped with wildcards (*pattern*) and matched case-insensitively.
     Example: -Ignore "Microsoft","OneDrive","Windows"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -OutputPath "C:\temp\restart-on-crash.ini"
     

     
 .EXAMPLE
     .\tasks-to-roc.ps1 -NoElevate -OutputPath "C:\temp\restart-on-crash.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Triggers "Boot","Logon" -OutputPath "C:\temp\boot-logon-tasks.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -EnabledOnly -OutputPath "C:\temp\enabled-tasks.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Triggers "Boot","Logon" -EnabledOnly -OutputPath "C:\temp\enabled-boot-logon.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -DisableTasks -OutputPath "C:\temp\restart-on-crash.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Triggers "Boot","Logon" -DisableTasks -OutputPath "C:\temp\boot-logon-disabled.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Merge -OutputPath "C:\temp\existing-config.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -WriteExtra -OutputPath "C:\temp\restart-on-crash-with-extras.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Ignore "Microsoft","OneDrive" -OutputPath "C:\temp\filtered-tasks.ini"
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
# TASK CLASSES
# =============================================================================

# Executable class to hold executable information
class Executable {
    [string]$Path
    [string]$Arguments
    
    Executable([string]$path, [string]$arguments = "") {
        $this.Path = $path
        $this.Arguments = $arguments
    }
    
    [string]ToString() {
        if ($this.Arguments) {
            return "`"$($this.Path)`" $($this.Arguments)"
        }
        return "`"$($this.Path)`""
    }
    
    [string]GetFileName() {
        return [System.IO.Path]::GetFileName($this.Path)
    }
    
    [bool]Exists() {
        return [System.IO.File]::Exists($this.Path)
    }
}

# Task class to hold scheduled task information
class ScheduledTask {
    [string]$Path
    [string]$Name
    [Executable[]]$Executables
    [string[]]$Triggers
    [bool]$Enabled
    [string]$WorkingDirectory
    
    ScheduledTask([string]$path, [string]$name) {
        $this.Path = $path
        $this.Name = $name
        $this.Executables = @()
        $this.Triggers = @()
        $this.Enabled = $true
        $this.WorkingDirectory = ""
    }
    
    [void]AddExecutable([Executable]$executable) {
        $this.Executables += $executable
    }
    
    [void]AddTrigger([string]$trigger) {
        if ($trigger -and -not ($this.Triggers -contains $trigger)) {
            $this.Triggers += $trigger
        }
    }
    
    [Executable]GetPrimaryExecutable() {
        if ($this.Executables.Count -gt 0) {
            return $this.Executables[0]
        }
        return $null
    }
    
    [string]GetPrimaryExecutablePath() {
        $primary = $this.GetPrimaryExecutable()
        if ($primary) {
            return $primary.Path
        }
        return ""
    }
    
    [string]GetPrimaryExecutableFileName() {
        $primary = $this.GetPrimaryExecutable()
        if ($primary) {
            return $primary.GetFileName()
        }
        return ""
    }
    
    [string]GetCommandString() {
        $primary = $this.GetPrimaryExecutable()
        if ($primary) {
            return $primary.ToString()
        }
        return ""
    }
    
    [bool]HasValidExecutable() {
        $primary = $this.GetPrimaryExecutable()
        if ($primary) {
            return $primary.Exists()
        }
        return $false
    }
    
    [bool]ShouldBeIgnored([string[]]$ignorePatterns) {
        if ($ignorePatterns.Count -eq 0) { return $false }
        
        foreach ($pattern in $ignorePatterns) {
            if ($this.Path -ilike "*$pattern*") {
                return $true
            }
        }
        return $false
    }
    
    [bool]HasAnyTrigger([string[]]$triggers) {
        if ($triggers.Count -eq 0) { return $true }
        
        foreach ($trigger in $this.Triggers) {
            if ($triggers -contains $trigger) {
                return $true
            }
        }
        return $false
    }
    
    [string]ToString() {
        return "$($this.Path)\$($this.Name) -> $($this.GetCommandString())"
    }
}

# ApplicationEntry class to hold RestartOnCrash application configuration
class ApplicationEntry {
    [string]$FileName
    [string]$WindowTitle
    [int]$Enabled
    [string]$Command
    [string]$WorkingDirectory
    [int]$CommandEnabled
    [int]$CrashNotResponding
    [int]$CrashNotRunning
    [int]$KillIfHanged
    [int]$CloseProblemReporter
    [int]$DelayEnabled
    [int]$CrashDelay
    [string]$Triggers
    
    ApplicationEntry() {
        $this.FileName = ""
        $this.WindowTitle = ""
        $this.Enabled = 1
        $this.Command = ""
        $this.WorkingDirectory = ""
        $this.CommandEnabled = 1
        $this.CrashNotResponding = 1
        $this.CrashNotRunning = 0
        $this.KillIfHanged = 1
        $this.CloseProblemReporter = 1
        $this.DelayEnabled = 1
        $this.CrashDelay = 60
        $this.Triggers = ""
    }
    
    ApplicationEntry([hashtable]$settings, [hashtable]$defaults) {
        if (-not $defaults) { $defaults = $Script:DefaultAppSettings }

        $this.FileName = $settings.FileName ?? $defaults.FileName
        $this.WindowTitle = $settings.WindowTitle ?? $defaults.WindowTitle
        $this.Enabled = $settings.Enabled ?? $defaults.Enabled
        $this.Command = $settings.Command ?? $defaults.Command
        $this.WorkingDirectory = $settings.WorkingDirectory ?? $defaults.WorkingDirectory
        $this.CommandEnabled = $settings.CommandEnabled ?? $defaults.CommandEnabled
        $this.CrashNotResponding = $settings.CrashNotResponding ?? $defaults.CrashNotResponding
        $this.CrashNotRunning = $settings.CrashNotRunning ?? $defaults.CrashNotRunning
        $this.KillIfHanged = $settings.KillIfHanged ?? $defaults.KillIfHanged
        $this.CloseProblemReporter = $settings.CloseProblemReporter ?? $defaults.CloseProblemReporter
        $this.DelayEnabled = $settings.DelayEnabled ?? $defaults.DelayEnabled
        $this.CrashDelay = $settings.CrashDelay ?? $defaults.CrashDelay
        $this.Triggers = $settings.Triggers ?? $defaults.Triggers
    }
    
    [hashtable]ToHashtable() {
        return @{
            FileName             = $this.FileName
            WindowTitle          = $this.WindowTitle
            Enabled              = $this.Enabled
            Command              = $this.Command
            WorkingDirectory     = $this.WorkingDirectory
            CommandEnabled       = $this.CommandEnabled
            CrashNotResponding   = $this.CrashNotResponding
            CrashNotRunning      = $this.CrashNotRunning
            KillIfHanged         = $this.KillIfHanged
            CloseProblemReporter = $this.CloseProblemReporter
            DelayEnabled         = $this.DelayEnabled
            CrashDelay           = $this.CrashDelay
            Triggers             = $this.Triggers
        }
    }
    
    [void]ApplyOverrides([hashtable]$overrides) {
        foreach ($key in $overrides.Keys) {
            if ($this.PSObject.Properties.Name -contains $key) {
                $this.$key = $overrides[$key]
            }
        }
    }
    
    [string]ToString() {
        return "ApplicationEntry: $($this.FileName)"
    }
}

# =============================================================================

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
            # Get the task name from the ScheduledTask object
            $taskName = $task.Name
            
            Write-Host "  Processing: $($task.ToString())" -ForegroundColor Gray
            
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
            Write-Host "  Error processing: $($task.ToString()) - $($_.Exception.Message)" -ForegroundColor Red
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

function Convert-TriggerTypeToShortName {
    param([string]$TriggerType)
    
    switch ($TriggerType) {
        "BootTrigger" { return "Boot" }
        "LogonTrigger" { return "Logon" }
        "TimeTrigger" { return "Time" }
        "CalendarTrigger" { return "Calendar" }
        "IdleTrigger" { return "Idle" }
        "EventTrigger" { return "Event" }
        "RegistrationTrigger" { return "Registration" }
        "SessionStateChangeTrigger" { return "SessionStateChange" }
        default { return $TriggerType }
    }
}

# Function to extract triggers from XML task
function Get-TriggersFromXml {
    param([object]$Xml)
    
    $taskTriggers = @()
    
    if ($Xml.Task.Triggers) {
        foreach ($trigger in $Xml.Task.Triggers.ChildNodes) {
            if (-not $trigger -or -not $trigger.LocalName) { continue }
            $taskTriggers += Convert-TriggerTypeToShortName -TriggerType $($trigger.LocalName)
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
            $triggerShortName = ""
            
            # Convert trigger type to short name for comparison
            switch ($triggerType) {
                "BootTrigger" { $triggerShortName = "Boot" }
                "LogonTrigger" { $triggerShortName = "Logon" }
                "TimeTrigger" { $triggerShortName = "Time" }
                "CalendarTrigger" { $triggerShortName = "Calendar" }
                "IdleTrigger" { $triggerShortName = "Idle" }
                "EventTrigger" { $triggerShortName = "Event" }
                "RegistrationTrigger" { $triggerShortName = "Registration" }
                "SessionStateChangeTrigger" { $triggerShortName = "SessionStateChange" }
                default { $triggerShortName = $triggerType }
            }
            
            # Check if this trigger type is in the specified triggers
            if ($SpecifiedTriggers -contains $triggerShortName) {
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

# Function to create application entry from ScheduledTask object
function New-ApplicationEntry {
    param(
        [ScheduledTask]$Task
    )
    
    # Get primary executable
    $primaryExecutable = $Task.GetPrimaryExecutable()
    if (-not $primaryExecutable) {
        return $null
    }
    
    # Create application entry with default settings
    $app = [ApplicationEntry]::new($null, $Script:DefaultAppSettings)
    
    # Set basic properties
    $app.FileName = $primaryExecutable.GetFileName()
    $app.Command = $primaryExecutable.ToString()
    $app.WorkingDirectory = Format-PathWithQuotes -Path $Task.WorkingDirectory
    $app.Triggers = $Task.Triggers -join ","
    
    # Apply application-specific overrides if they exist
    if ($Script:AppOverrides.ContainsKey($primaryExecutable.Path)) {
        $app.ApplyOverrides($Script:AppOverrides[$primaryExecutable.Path])
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

# Function to process task XML file and return ScheduledTask object
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
        
        # Create task object
        $task = [ScheduledTask]::new($taskPath, $XmlFile.Name)
        
        # Check if task should be ignored based on task path
        if ($task.ShouldBeIgnored($IgnorePatterns)) {
            Write-Host "Ignoring task due to pattern match: $($task.ToString())" -ForegroundColor Yellow
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
        
        # Skip if no executable found
        if (-not $executablePath) { return $null }
        
        # Skip RestartOnCrash.exe to prevent processing itself (case insensitive)
        if ($executablePath -ilike "*RestartOnCrash.exe*") {
            Write-Verbose "Skipping RestartOnCrash.exe: $($task.ToString()) -> $executablePath"
            return $null
        }
        
        # Verify executable exists
        if (-not [System.IO.File]::Exists($executablePath)) { return $null }
        
        # Extract working directory
        $workingDirectory = Get-WorkingDirectoryFromXml -Xml $xml
        
        # Extract triggers
        $taskTriggers = Get-TriggersFromXml -Xml $xml
        
        # Set task properties
        $task.Enabled = Test-TaskIsEnabled -Xml $xml
        $task.WorkingDirectory = $workingDirectory
        
        # Add executable
        $executable = [Executable]::new($executablePath, $arguments)
        $task.AddExecutable($executable)
        
        # Add triggers
        foreach ($trigger in $taskTriggers) {
            $task.AddTrigger($trigger)
        }
        
        # Check if task has specified triggers (if any specified)
        if (-not $task.HasAnyTrigger($SpecifiedTriggers)) {
            return $null
        }
        
        # Debug: Show first few tasks
        if ($ProcessedCount -le 10) {
            Write-Host "Task: $($task.ToString())" -ForegroundColor DarkGray
            Write-Host "  Executable: $($task.GetPrimaryExecutablePath())" -ForegroundColor DarkGray
            if ($arguments) {
                Write-Host "  Arguments: $arguments" -ForegroundColor DarkGray
            }
        }
        
        return $task
    }
    catch {
        Write-Verbose "Error processing task $($XmlFile.Name): $($_.Exception.Message)"
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
                        $existingApplications += [ApplicationEntry]::new($currentApp, $Script:DefaultAppSettings)
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
                $existingApplications += [ApplicationEntry]::new($currentApp, $Script:DefaultAppSettings)
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
        
        # Convert ApplicationEntry to hashtable for processing
        $appHashtable = $app.ToHashtable()
        
        foreach ($key in $appHashtable.Keys | Sort-Object) {
            # Skip Triggers field unless WriteExtra is enabled
            if ($key -eq "Triggers" -and -not $WriteExtra) { continue }
            
            $value = $appHashtable[$key]
            # The values are already properly formatted with quotes where needed
            $content += "$key=$value"
        }
        $content += ""
    }
    
    # Write to file
    $content | Out-File -FilePath $FilePath -Encoding UTF8
}

function Sanitize-CommandLine {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0)]
        [string]$CommandLine
    )
    process {
        if ($null -ne $CommandLine) {
            return $CommandLine -replace '"', "'"
        }
    }
}

# Main script logic
try {
    Set-Variable -Name "commandLine" -Value ($MyInvocation.Line | Sanitize-CommandLine) -Scope Global
    Write-Host "Script Command Line: $commandLine"

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
        # Get primary executable path for deduplication
        $executablePath = $task.GetPrimaryExecutablePath()
        
        # Skip if already processed (duplicate executable)
        if ($processedExecutables.ContainsKey($executablePath)) {
            continue
        }
        
        # Create application entry
        $app = New-ApplicationEntry -Task $task
        
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
        $processedExecutables[$executablePath] = $true
        
        Write-Host "Added: $($task.ToString()) -> $($task.GetPrimaryExecutablePath())" -ForegroundColor Cyan
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