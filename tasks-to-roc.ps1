[CmdletBinding()]
#Requires -Version 7.2
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
     
 .PARAMETER StartupTasks
     Process scheduled tasks that are triggered on Boot or Logon and are enabled.
     This is equivalent to using -Triggers Boot,Logon -EnabledOnly.
     If not specified, no scheduled tasks will be processed.
     Note: This parameter is required to process any startup-related items.
     
 .PARAMETER Disable
     Stop and disable scheduled tasks and move startup files to AutorunsDisabled\ subfolder after successful conversion (requires administrator privileges).
     
 .PARAMETER Merge
     Merge new entries into existing INI file, only adding entries where FileName doesn't already exist.
     
 .PARAMETER WriteExtra
     Include extra fields in the INI output (Triggers and GeneratorCommand). By default, these are excluded for cleaner output.
     
 .PARAMETER NoDuplicates
     Enable deduplication of application entries. When specified, duplicate entries based on Command property will be removed.
     By default, all entries are kept regardless of duplicates.
     
 .PARAMETER Ignore
     Array of patterns to ignore tasks based on their task path. Patterns are automatically wrapped with wildcards (*pattern*) and matched case-insensitively.
     Example: -Ignore "Microsoft","OneDrive","Windows"
     
 .PARAMETER StartupFiles
     Include startup files from common startup locations (Startup folders, Win.ini, etc.).
     
 .PARAMETER StartupRegistry
     Include startup applications from registry keys (Run, RunOnce, etc.).
     
 .PARAMETER StartupScripts
     Include logon scripts from Group Policy and registry.
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -StartupTasks -OutputPath "C:\temp\restart-on-crash.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -StartupTasks -NoElevate -OutputPath "C:\temp\restart-on-crash.ini"
     
  .EXAMPLE
     .\tasks-to-roc.ps1 -StartupTasks -OutputPath "C:\temp\startup-tasks.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -StartupTasks -Disable -OutputPath "C:\temp\startup-tasks-disabled.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Disable -OutputPath "C:\temp\restart-on-crash.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Merge -OutputPath "C:\temp\existing-config.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -WriteExtra -OutputPath "C:\temp\restart-on-crash-with-extras.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -Ignore "Microsoft","OneDrive" -OutputPath "C:\temp\filtered-tasks.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -StartupFiles -StartupRegistry -OutputPath "C:\temp\startup-apps.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -StartupFiles -StartupRegistry -StartupScripts -OutputPath "C:\temp\all-startup.ini"
     
 .EXAMPLE
     .\tasks-to-roc.ps1 -StartupTasks -NoDuplicates -OutputPath "C:\temp\deduplicated-tasks.ini"
#>

param(
    [string]$OutputPath = ".\restart-on-crash.ini",
    [switch]$NoElevate,
    [switch]$Disable,
    [switch]$Merge,
    [switch]$WriteExtra,
    [switch]$NoDuplicates,
    [string[]]$Ignore = @("RestartOnCrash"),
    [switch]$Tasks,
    [switch]$Files,
    [switch]$Registry,
    [switch]$Scripts
)

$Verbose = $true

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
    Write-Host "This script requires administrator privileges." -ForegroundColor Yellow
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
    [string[]]$Arguments

    Executable([string]$path, [object]$arguments = $null) {
        $this.Path = $path
        if ($null -eq $arguments) {
            $this.Arguments = @()
        }
        elseif ($arguments -is [string]) {
            if ($arguments.Trim()) {
                try {
                    # Use PSParser to split arguments string into array, respecting quotes
                    $parsedArgs = [System.Management.Automation.PSParser]::Tokenize($arguments, [ref]$null) | Where-Object { $_.Type -eq 'String' -or $_.Type -eq 'CommandArgument' } | ForEach-Object { $_.Content }
                    $this.Arguments = $parsedArgs
                }
                catch {
                    # Fallback: just use the string as a single argument
                    $this.Arguments = @($arguments)
                }
            } else {
                $this.Arguments = @()
            }
        }
        elseif ($arguments -is [array]) {
            $this.Arguments = $arguments
        }
        else {
            $this.Arguments = @()
        }
    }

    Executable([string]$path, [string[]]$arguments) {
        $this.Path = $path
        $this.Arguments = $arguments
    }

    [string]ToString() {
        $result = Format-PathWithQuotes -Path $this.Path -ForceQuotes
        if ($this.Arguments -and $this.Arguments.Count -gt 0) {
            # Join arguments into a single string, quoting as needed
            $formattedArgs = ($this.Arguments | ForEach-Object {
                if ($_ -match '\s' -or $_ -match '[`"]') {
                    # Quote argument if it contains spaces or quotes
                    '"' + ($_ -replace '"', '""') + '"'
                } else {
                    $_
                }
            }) -join ' '
            $result += " $formattedArgs"
        }
        return $result
    }

    static [Executable]FromCommandLine([string]$commandLine) {
        $parsedCommand = Parse-CommandLine -CommandLine $commandLine
        $executablePath = if ($parsedCommand.PathItem -is [System.IO.FileInfo]) { $parsedCommand.PathItem.FullName } else { $parsedCommand.PathItem }
        $argsArray = @()
        if ($parsedCommand.Arguments -is [System.Collections.IEnumerable]) {
            $argsArray = @($parsedCommand.Arguments)
        }
        return [Executable]::new($executablePath, $argsArray)
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
        return "$($this.Path)\$($this.Name) [$($this.Triggers -join ',')] -> $($this.GetCommandString())"
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
    [int]$FileNameExists
    [int]$CommandExists
    [string]$Source
    
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
        $this.FileNameExists = 0
        $this.CommandExists = 0
        $this.Source = ""
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
        $this.FileNameExists = $settings.FileNameExists ?? 0
        $this.CommandExists = $settings.CommandExists ?? 0
        $this.Source = $settings.Source ?? ""
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
            _Triggers             = $this.Triggers
            _FileNameExists       = $this.FileNameExists
            _CommandExists        = $this.CommandExists
            _Source               = if ($this.Source -match ' ') { "`"$($this.Source)`"" } else { $this.Source }
        }
    }
    
    [void]ApplyOverrides([hashtable]$overrides) {
        foreach ($key in $overrides.Keys) {
            if ($this.PSObject.Properties.Name -contains $key) {
                $this.$key = $overrides[$key]
            }
        }
    }
    
    [void]CleanupTriggers() {
        if ($this.Triggers) {
            $triggerArray = $this.Triggers -split ','
            $uniqueTriggers = $triggerArray | Sort-Object -Unique
            $this.Triggers = $uniqueTriggers -join ','
        }
    }
    
    [void]Update() {
        # Check if FileName exists
        if (-not [string]::IsNullOrWhiteSpace($this.FileName)) {
            try {
                # Try to resolve the file path
                $resolvedPath = [System.IO.Path]::GetFullPath($this.FileName)
                $this.FileNameExists = if (Test-Path $resolvedPath -PathType Leaf) { 1 } else { 0 }
            }
            catch {
                $this.FileNameExists = 0
            }
        }
        else {
            $this.FileNameExists = 0
        }
        
        # Check if Command executable exists
        if (-not [string]::IsNullOrWhiteSpace($this.Command)) {
            try {
                # Extract the executable path from the command
                $commandParts = $this.Command -split '\s+', 2
                $executablePath = $commandParts[0]
                
                # Remove quotes if present
                $executablePath = $executablePath -replace '^["'']|["'']$', ''
                
                # Try to resolve the executable path
                $resolvedPath = [System.IO.Path]::GetFullPath($executablePath)
                $this.CommandExists = if (Test-Path $resolvedPath -PathType Leaf) { 1 } else { 0 }
            }
            catch {
                $this.CommandExists = 0
            }
        }
        else {
            $this.CommandExists = 0
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

# Function to extract executable path and arguments from XML task
function Get-ExecutablePathAndArgsFromXml {
    param([object]$Xml)
    
    $executables = @()
    
    # Look for executable and arguments in various possible locations
    if ($Xml.Task.Actions.Exec.Command) {
        # Handle multiple Exec actions properly
        if ($Xml.Task.Actions.Exec.Command -is [array]) {
            # Multiple Exec actions - process each one
            for ($i = 0; $i -lt $Xml.Task.Actions.Exec.Command.Count; $i++) {
                $command = $Xml.Task.Actions.Exec.Command[$i]
                $taskArgs = if ($Xml.Task.Actions.Exec.Arguments -is [array] -and $i -lt $Xml.Task.Actions.Exec.Arguments.Count) { 
                    $Xml.Task.Actions.Exec.Arguments[$i] 
                }
                else { 
                    $Xml.Task.Actions.Exec.Arguments 
                }
                
                Write-Verbose "[Get-ExecutablePathAndArgsFromXml] Processing Exec action $($i + 1) for Task $($Xml.Task.Name) -> $command"
                
                $parsedCommand = Parse-CommandLine -CommandLine $command
                $executablePath = if ($parsedCommand[0] -is [System.IO.FileInfo]) { $parsedCommand[0].FullName } else { $parsedCommand[0] }
                $arguments = $parsedCommand[1] -join " "
                
                # Get arguments if present in XML (this takes precedence)
                if ($taskArgs) {
                    if ($arguments) {
                        $arguments += " " + $taskArgs
                    }
                    else {
                        $arguments = $taskArgs
                    }
                }
                
                $executables += [Executable]::new($executablePath, $arguments)
            }
        }
        else {
            # Single Exec action
            $command = $Xml.Task.Actions.Exec.Command
            $taskArgs = $Xml.Task.Actions.Exec.Arguments
            Write-Verbose "[Get-ExecutablePathAndArgsFromXml] Will try to parse command line for Task $($Xml.Task.Name) -> $command"
            
            $parsedCommand = Parse-CommandLine -CommandLine $command
            $executablePath = if ($parsedCommand[0] -is [System.IO.FileInfo]) { $parsedCommand[0].FullName } else { $parsedCommand[0] }
            $arguments = $parsedCommand[1] -join " "
            
            # Get arguments if present in XML (this takes precedence)
            if ($taskArgs) {
                if ($arguments) {
                    $arguments += " " + $taskArgs
                }
                else {
                    $arguments = $taskArgs
                }
            }
            
            $executables += [Executable]::new($executablePath, $arguments)
        }
    }
    elseif ($Xml.Task.Actions.Exec.WorkingDirectory) {
        # Sometimes the command is in the working directory
        $workingDir = $Xml.Task.Actions.Exec.WorkingDirectory
        if ($workingDir -and (Test-Path $workingDir)) {
            $exeFiles = Get-ChildItem -Path $workingDir -Filter "*.exe" -ErrorAction SilentlyContinue
            if ($exeFiles.Count -eq 1) {
                $executablePath = $exeFiles[0].FullName
                $executables += [Executable]::new($executablePath, "")
            }
        }
    }
    
    return $executables
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

# Function to check if item should be ignored based on patterns
function Test-ItemShouldBeIgnored {
    param(
        [string]$ItemName,
        [string[]]$IgnorePatterns
    )
    
    # If no ignore patterns specified, don't ignore anything
    if ($IgnorePatterns.Count -eq 0) {
        return $false
    }
    
    # Check if item name matches any ignore pattern (case-insensitive)
    foreach ($pattern in $IgnorePatterns) {
        if ($ItemName -like "*$pattern*") {
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

# Function to convert trigger type to short name
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

# Function to disable a single scheduled task
function Disable-SingleScheduledTask {
    param(
        [string]$TaskName,
        [string]$TaskPath
    )
    
    try {
        Write-Host "  Processing: $TaskPath\$TaskName" -ForegroundColor Gray
        
        # First, try to stop the task if it's running
        try {
            $runningTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($runningTask -and $runningTask.State -eq "Running") {
                Write-Host "    Stopping running task..." -ForegroundColor Yellow
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                Write-Host "    Stopped: $TaskName" -ForegroundColor Green
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
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-Host "    Disabled: $TaskName" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "    Failed to disable: $TaskName - $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "  Error processing: $TaskPath\$TaskName - $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Function to format path with quotes if needed (now pipable)
function Format-PathWithQuotes {
    <#
    .SYNOPSIS
        Formats a path with quotes if needed for command line usage. Now supports pipeline input.
    
    .DESCRIPTION
        Intelligently formats a path string for command line usage by adding quotes only when necessary.
        Handles various edge cases including paths with spaces, special characters, and existing quotes.
        Supports both Windows and Unix-style paths.
        Accepts input from the pipeline or via the -Path parameter.
    
    .PARAMETER Path
        The path string to format. Can be a file path, directory path, or any string that needs
        command line formatting. Accepts pipeline input.
    
    .PARAMETER ForceQuotes
        Optional. Forces quotes around the path even if not strictly necessary.
        Useful for consistency in command line generation.
    
    .PARAMETER QuoteType
        Optional. Specifies the type of quotes to use. Valid values are:
        - "Double" (default): Uses double quotes (")
        - "Single": Uses single quotes (')
        - "Auto": Automatically chooses based on content (prefers double, uses single if path contains double quotes)
    
    .RETURNS
        [string] The formatted path with appropriate quotes if needed.
    
    .EXAMPLE
        PS> Format-PathWithQuotes "C:\Program Files\App\app.exe"
        Returns: "C:\Program Files\App\app.exe"
    
    .EXAMPLE
        PS> "C:\App\app.exe" | Format-PathWithQuotes
        Returns: C:\App\app.exe
    
    .EXAMPLE
        PS> "C:\App\app.exe" | Format-PathWithQuotes -ForceQuotes
        Returns: "C:\App\app.exe"
    
    .EXAMPLE
        PS> "C:\App\app.exe" | Format-PathWithQuotes -QuoteType Single
        Returns: 'C:\App\app.exe'
    
    .EXAMPLE
        PS> 'C:\App\app.exe "with quotes"' | Format-PathWithQuotes
        Returns: 'C:\App\app.exe "with quotes"'
    
    .EXAMPLE
        PS> "" | Format-PathWithQuotes
        Returns: ""
    
    .NOTES
        - Handles null, empty, and whitespace-only strings
        - Removes existing quotes before processing
        - Detects paths with spaces, special characters, and existing quotes
        - Supports both Windows and Unix-style path separators
        - Preserves the original path structure while ensuring command line compatibility
        - Now pipable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $false)]
        [switch]$ForceQuotes,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Double", "Single", "Auto")]
        [string]$QuoteType = "Double"
    )
    process {
        # Handle null, empty, or whitespace-only strings
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return ""
        }
        
        # Remove any existing quotes first (both single and double)
        $cleanPath = $Path -replace '^["'']|["'']$', ''
        
        # Determine if quotes are needed
        $needsQuotes = $ForceQuotes -or 
        $cleanPath -match ' ' -or # Contains spaces (only actual spaces, not all whitespace)
        $cleanPath -match '["'']' -or # Contains quotes
        $cleanPath -match '[&|<>^]' -or # Contains special command line characters
        $cleanPath -match '^[^a-zA-Z]:' -or # Not a valid drive letter
        $cleanPath -match '^[a-zA-Z]:[^\\]'          # Drive letter without backslash
        
        if (-not $needsQuotes) {
            return $cleanPath
        }
        
        # Determine quote type
        $useDoubleQuotes = $true
        if ($QuoteType -eq "Single") {
            $useDoubleQuotes = $false
        }
        elseif ($QuoteType -eq "Auto") {
            # Use single quotes if the path contains double quotes
            $useDoubleQuotes = $cleanPath -notmatch '"'
        }
        
        # Format with appropriate quotes
        if ($useDoubleQuotes) {
            return "`"$cleanPath`""
        }
        else {
            return "'$cleanPath'"
        }
    }
}

# Function to parse command string and return path and arguments array (now pipable)
function Parse-CommandLine {
    <#
    .SYNOPSIS
        Parses a command line string and returns the executable path and arguments array.

    .DESCRIPTION
        Intelligently parses a command line string, handling quoted arguments, escaped quotes,
        and spaces within quoted strings. Returns a tuple containing the executable path (as Get-Item object or string) 
        and arguments array.

    .PARAMETER CommandLine
        The command line string to parse (e.g., 'C:\Program Files\App\app.exe "arg with spaces" arg2')

    .RETURNS
        [pscustomobject] An object with:
        - PathItem: [object] Get-Item object of the path if successful, or [string] the path if Get-Item throws an error
        - Arguments: [string[]] Array of remaining arguments without quotes

    .EXAMPLE
        PS> "C:\Program Files\App\app.exe arg1 arg2" | Parse-CommandLine
        Returns: [pscustomobject] with PathItem and Arguments

    .EXAMPLE
        PS> Parse-CommandLine 'C:\App\app.exe "argument with spaces" arg2'
        Returns: [pscustomobject] with PathItem and Arguments

    .EXAMPLE
        PS> Parse-CommandLine 'C:\App\app.exe "path with \"quotes\"" arg2'
        Returns: [pscustomobject] with PathItem and Arguments

    .NOTES
        - Throws an exception if the command line is null or empty
        - Returns Get-Item object if the path exists, otherwise returns the path as string
        - Handles escaped quotes using backslash (e.g., \")
        - Supports both single and double quoted arguments
        - Now pipable: accepts input from pipeline or parameter
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0, Mandatory = $true)]
        [string]$CommandLine
    )
    process {
        if ([string]::IsNullOrWhiteSpace($CommandLine)) {
            throw "Command line cannot be null or empty"
        }

        Write-Verbose "Parsing command line: '$CommandLine'"

        # Initialize variables
        $path = ""
        $arguments = @()
        $currentArg = ""
        $inQuotes = $false
        $escapeNext = $false

        # Process each character
        for ($i = 0; $i -lt $CommandLine.Length; $i++) {
            $char = $CommandLine[$i]

            if ($escapeNext) {
                $currentArg += $char
                $escapeNext = $false
                continue
            }

            if ($char -eq '\' -and $i -lt ($CommandLine.Length - 1) -and $CommandLine[$i + 1] -eq '"') {
                $escapeNext = $true
                continue
            }

            if ($char -eq '"') {
                $inQuotes = -not $inQuotes
                continue
            }

            if ($char -eq ' ' -and -not $inQuotes) {
                # End of current argument
                if ($currentArg -ne "") {
                    if ($path -eq "") {
                        $path = $currentArg
                    }
                    else {
                        $arguments += $currentArg
                    }
                    $currentArg = ""
                }
                continue
            }

            $currentArg += $char
        }

        # Handle the last argument
        if ($currentArg -ne "") {
            if ($path -eq "") {
                $path = $currentArg
            }
            else {
                $arguments += $currentArg
            }
        }

        Write-Verbose "Parsed path: '$path', arguments: $($arguments -join ' ')"

        # Check if path is empty after parsing
        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-Verbose "Path is empty after parsing, throwing error"
            throw "Failed to parse executable path from command line: '$CommandLine'"
        }

        # Simple approach: split by space and check if first part is already a valid path
        # If not, keep adding parts until we find a valid path
        $originalPath = $path
        $originalArguments = $arguments.Clone()

        # First, try the path as-is
        $testPath = [Environment]::ExpandEnvironmentVariables($path)
        try {
            $testItem = Get-Item -Path $testPath -ErrorAction Stop
            Write-Verbose "Path is valid as-is: '$testPath'"
        }
        catch {
            Write-Verbose "Path is not valid as-is: '$testPath'"

            # Parse the command line properly, respecting quoted strings
            $parts = @()
            $currentPart = ""
            $inQuotes = $false
            $escapeNext = $false

            for ($i = 0; $i -lt $CommandLine.Length; $i++) {
                $char = $CommandLine[$i]

                if ($escapeNext) {
                    $currentPart += $char
                    $escapeNext = $false
                    continue
                }

                if ($char -eq '\' -and $i -lt ($CommandLine.Length - 1) -and $CommandLine[$i + 1] -eq '"') {
                    $escapeNext = $true
                    continue
                }

                if ($char -eq '"') {
                    $inQuotes = -not $inQuotes
                    $currentPart += $char
                    continue
                }

                if ($char -eq ' ' -and -not $inQuotes) {
                    # End of current part
                    if ($currentPart -ne "") {
                        $parts += $currentPart
                        $currentPart = ""
                    }
                    continue
                }

                $currentPart += $char
            }

            # Handle the last part
            if ($currentPart -ne "") {
                $parts += $currentPart
            }

            Write-Verbose "Properly parsed command line into parts: $($parts -join ' | ')"

            # If the path is not valid and we have multiple parts, try to combine them
            # This handles the case where an unquoted path with spaces was incorrectly split
            if ($parts.Count -gt 1) {
                Write-Verbose "Path is not valid and we have multiple parts, trying to combine them"

                # Try combining parts until we find a valid path
                $combinedPath = $parts[0]
                $remainingParts = $parts[1..($parts.Count - 1)]

                foreach ($part in $remainingParts) {
                    $testPath = [Environment]::ExpandEnvironmentVariables("$combinedPath $part")

                    try {
                        $testItem = Get-Item -Path $testPath -ErrorAction Stop
                        Write-Verbose "Found valid path by combining: '$testPath'"
                        $path = "$combinedPath $part"
                        # The arguments should be the parts that come after the valid path
                        $partIndex = $remainingParts.IndexOf($part)
                        if ($partIndex -ge 0 -and $partIndex -lt ($remainingParts.Count - 1)) {
                            $arguments = $remainingParts[($partIndex + 1)..($remainingParts.Count - 1)]
                        }
                        else {
                            $arguments = @()
                        }
                        $foundValidPath = $true
                        break
                    }
                    catch {
                        try {
                            $commandInfo = Get-Command -Name "$combinedPath $part" -ErrorAction Stop
                            Write-Verbose "Found executable in PATH by combining: $($commandInfo.Source)"
                            $path = "$combinedPath $part"
                            # The arguments should be the parts that come after the valid path
                            $partIndex = $remainingParts.IndexOf($part)
                            if ($partIndex -ge 0 -and $partIndex -lt ($remainingParts.Count - 1)) {
                                $arguments = $remainingParts[($partIndex + 1)..($remainingParts.Count - 1)]
                            }
                            else {
                                $arguments = @()
                            }
                            $foundValidPath = $true
                            break
                        }
                        catch {
                            Write-Verbose "Combination not valid: '$testPath', continuing"
                            $combinedPath = "$combinedPath $part"
                        }
                    }
                }

                # If we never found a valid path, use the original
                if (-not $foundValidPath) {
                    Write-Host "Could not find a valid path by combining parts, using original path: '$originalPath'" -ForegroundColor Red
                    $path = $originalPath
                    $arguments = $originalArguments
                }
            }
            else {
                # Only one part, just use the original path
                Write-Verbose "Path is not valid and only one part, using original path: '$originalPath'"
                $path = $originalPath
                $arguments = $originalArguments
            }
        }

        # Now get the final Get-Item object for the resolved path
        $expandedPath = [Environment]::ExpandEnvironmentVariables($path)

        # Final safety check to ensure we don't pass empty path to Get-Item
        if ([string]::IsNullOrWhiteSpace($expandedPath)) {
            Write-Verbose "Expanded path is empty, throwing error"
            throw "Failed to resolve executable path from command line: '$CommandLine'"
        }

        try {
            $pathItem = Get-Item -Path $expandedPath -ErrorAction Stop
            Write-Host "Successfully parsed $($pathItem.PSIsContainer ? 'directory' : 'file'): $($pathItem.FullName) $($arguments -join ' ')" -ForegroundColor Green
            [PSCustomObject]@{
                PathItem  = $pathItem
                Arguments = $arguments
            }
        }
        catch {
            Write-Verbose "Failed to get Get-Item object for '$expandedPath': $($_.Exception.Message)"

            # Try to find the executable in the system PATH
            try {
                # Check if path is empty before calling Get-Command
                if ([string]::IsNullOrWhiteSpace($path)) {
                    Write-Verbose "Path is empty, cannot search in PATH"
                    throw "Path is empty"
                }

                $commandInfo = Get-Command -Name $path -ErrorAction Stop
                Write-Host "Found executable in PATH: $($commandInfo.Source) $($arguments -join ' ')" -ForegroundColor Green
                [PSCustomObject]@{
                    PathItem  = (Get-Item -Path $commandInfo.Source)
                    Arguments = $arguments
                }
            }
            catch {
                Write-Verbose "Failed to find executable in PATH: $path"
                # Return the expanded path as string if both Get-Item and Get-Command fail
                if ([string]::IsNullOrWhiteSpace($expandedPath)) {
                    Write-Verbose "Expanded path is empty, throwing error"
                    throw "Failed to resolve executable path from command line: '$CommandLine'"
                }
                [PSCustomObject]@{
                    PathItem  = $expandedPath
                    Arguments = $arguments
                }
            }
        }
    }
}

function Sanitize-CommandLine {
    <#
    .SYNOPSIS
        Sanitizes a command line by converting double quotes to single quotes. Now pipable.

    .DESCRIPTION
        Converts all double quotes in a command line string to single quotes.
        This is useful for command line sanitization and consistency.
        Now supports pipeline input.

    .PARAMETER CommandLine
        The command line string to sanitize. Accepts pipeline input.

    .RETURNS
        [string] The sanitized command line with single quotes instead of double quotes.

    .EXAMPLE
        PS> Sanitize-CommandLine 'C:\App\app.exe "argument with spaces"'
        Returns: C:\App\app.exe 'argument with spaces'

    .EXAMPLE
        PS> 'C:\App\app.exe "argument with spaces"' | Sanitize-CommandLine
        Returns: C:\App\app.exe 'argument with spaces'
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0, Mandatory = $true)]
        [string]$CommandLine
    )
    process {
        if ($null -ne $CommandLine) {
            # Simple sanitization: replace all double quotes with single quotes
            $CommandLine -replace '"', "'"
        }
    }
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

# Function to process task XML file and return ApplicationEntry object directly
function Process-TaskXmlFileToApplicationEntry {
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
        
        # Check if task should be ignored based on task path
        if (Test-TaskShouldBeIgnored -TaskPath $taskPath -IgnorePatterns $IgnorePatterns) {
            Write-Host "Ignoring task due to pattern match: $taskPath\$($XmlFile.Name)" -ForegroundColor Yellow
            return $null
        }
        
        # Check if task is enabled (if EnabledOnly is specified)
        if ($EnabledOnly -and -not (Test-TaskIsEnabled -Xml $xml)) {
            return $null
        }
        
        Write-Verbose "[Process-TaskXmlFileToApplicationEntry] Will try to get executable path and arguments from task $($XmlFile.FullName)"
        $executables = Get-ExecutablePathAndArgsFromXml -Xml $xml
        
        # Skip if no executables found
        if ($executables.Count -eq 0) { 
            Write-Verbose "No executables found for task: $($XmlFile.Name)"
            return $null 
        }
        
        # Use the first executable for now (we could create multiple ApplicationEntry objects if needed)
        $primaryExecutable = $executables[0]
        $executablePath = $primaryExecutable.Path
        $arguments = $primaryExecutable.Arguments
        
        # Verify executable exists
        if (-not [System.IO.File]::Exists($executablePath)) { 
            Write-Verbose "Executable not found on disk: $executablePath"
            return $null 
        }
        
        # Extract working directory
        $workingDirectory = Get-WorkingDirectory -ExecutablePath $executablePath
        
        # Extract triggers
        $taskTriggers = Get-TriggersFromXml -Xml $xml
        
        # Debug: Show raw trigger extraction for first few tasks
        if ($ProcessedCount -le 10) {
            Write-Verbose "Raw triggers from XML for $($XmlFile.Name): $($taskTriggers -join ', ')"
        }
        
        # Check if task has specified triggers (if any specified)
        if ($SpecifiedTriggers.Count -gt 0) {
            $hasMatchingTrigger = $false
            foreach ($trigger in $taskTriggers) {
                if ($SpecifiedTriggers -contains $trigger) {
                    $hasMatchingTrigger = $true
                    break
                }
            }
            if (-not $hasMatchingTrigger) {
                Write-Verbose "Task filtered out - no matching triggers: $taskPath\$($XmlFile.Name)"
                return $null
            }
        }
        
        # Create ApplicationEntry object with default settings
        $app = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
        
        # Set basic properties
        $app.FileName = [System.IO.Path]::GetFileName($executablePath)
        $app.Source = "Scheduled Task: $($XmlFile.Name)"
        # Use Executable class to handle command line formatting
        $executable = [Executable]::new($executablePath, $arguments)
        $app.Command = $executable.ToString()
        $app.WorkingDirectory = Format-PathWithQuotes -Path $workingDirectory -ForceQuotes
        
        # Set triggers - join array with commas, but only if there are triggers
        if ($taskTriggers.Count -gt 0) {
            # Remove duplicates and join with commas
            $uniqueTriggers = $taskTriggers | Sort-Object -Unique
            $app.Triggers = $uniqueTriggers -join ","
            Write-Verbose "Setting triggers for $($app.FileName): $($app.Triggers)"
        }
        else {
            $app.Triggers = ""
            Write-Verbose "No triggers found for $($app.FileName)"
        }
        
        # Apply application-specific overrides if they exist
        if ($Script:AppOverrides.ContainsKey($executablePath)) {
            $app.ApplyOverrides($Script:AppOverrides[$executablePath])
        }
        
        Write-Verbose "Application: $($app.FileName) [$($app.Triggers)] -> $($app.Command)"
        
        return $app
    }
    catch {
        Write-Verbose "Error processing task $($XmlFile.Name): $($_.Exception.Message)"
        return $null
    }
}

# Function to read existing INI file and extract applications
function Read-ExistingIniFile {
    param([string]$FilePath)
    
    $existingApplications = @()
    $generalSettings = @{}

    if (-not (Test-Path $FilePath)) { return @{ Applications = @(); GeneralSettings = @{} } }
    
    try {
        $currentSection = ""
        $currentApp = @{}

        foreach ($line in (Get-Content $FilePath -ErrorAction Stop)) {
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            
            # Section header
            if ($line.StartsWith('[') -and $line.EndsWith(']')) {
                # Save previous application
                if ($currentSection.StartsWith('Application') -and $currentApp.Count -gt 0) {
                    # Fix WorkingDirectory quoting
                    if ($currentApp.WorkingDirectory) {
                        $currentApp.WorkingDirectory = "`"$($currentApp.WorkingDirectory -replace '^["'']|["'']$', '')`""
                    }
                    $existingApplications += [ApplicationEntry]::new($currentApp, $Script:DefaultAppSettings)
                    $currentApp = @{}
                }
                $currentSection = $line.Substring(1, $line.Length - 2)
                continue
            }
            
            # Key-value pair
            if ($line.Contains('=')) {
                $key, $value = $line.Split('=', 2) | ForEach-Object { $_.Trim() }
                if ($currentSection -eq "general") {
                    $generalSettings[$key] = $value
                }
                elseif ($currentSection.StartsWith('Application')) {
                    $currentApp[$key] = $value
                }
            }
        }
        
        # Handle last application
        if ($currentSection.StartsWith('Application') -and $currentApp.Count -gt 0) {
            if ($currentApp.WorkingDirectory) {
                $currentApp.WorkingDirectory = "`"$($currentApp.WorkingDirectory -replace '^["'']|["'']$', '')`""
            }
            $existingApplications += [ApplicationEntry]::new($currentApp, $Script:DefaultAppSettings)
        }

        Write-Host "Found $($existingApplications.Count) application sections in $FilePath" -ForegroundColor Gray
    }
    catch {
        Write-Warning "Error reading existing INI file: $($_.Exception.Message)"
    }
    
    return @{ Applications = $existingApplications; GeneralSettings = $generalSettings }
}

# Function to validate and clean up INI content
function Validate-IniContent {
    param(
        [string]$FilePath
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-Warning "INI file not found: $FilePath"
        return $false
    }
    
    $content = Get-Content $FilePath
    $validationErrors = @()
    $lineNumber = 0
    
    foreach ($line in $content) {
        $lineNumber++
        $line = $line.Trim()
        
        # Skip empty lines, comments, and section headers
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith('[')) {
            continue
        }
        
        # Check for key=value format
        if ($line.Contains('=')) {
            $parts = $line.Split('=', 2)
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            
            # Check for missing closing quotes in Command field
            if ($key -eq 'Command' -and $value.StartsWith('"') -and -not $value.EndsWith('"')) {
                $validationErrors += "Line $lineNumber`: Missing closing quote in Command field: $line"
            }
            
            # Check for empty values in required fields
            if ($key -in @('FileName', 'Command') -and [string]::IsNullOrWhiteSpace($value)) {
                $validationErrors += "Line $lineNumber`: Empty value for required field '$key'"
            }
        }
    }
    
    if ($validationErrors.Count -gt 0) {
        Write-Warning "Found $($validationErrors.Count) validation errors in $FilePath`:"
        foreach ($validationError in $validationErrors) {
            Write-Warning "  $validationError"
        }
        return $false
    }
    
    Write-Host "INI file validation passed: $FilePath" -ForegroundColor Green
    return $true
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
        # Handle WriteExtra fields - skip if not enabled
        if ($key -eq "_GeneratorCommand") {
            if (-not $WriteExtra) { continue }
        }
        
        $value = $GeneralSettings[$key]
        # Don't add extra quotes for GeneratorCommand as it already contains quotes
        if ($key -eq "_GeneratorCommand") {
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
        
        # Update existence information before writing
        $app.Update()
        
        $content += "[Application$i]"
        
        # Convert ApplicationEntry to hashtable for processing
        $appHashtable = $app.ToHashtable()
        
        foreach ($key in $appHashtable.Keys | Sort-Object) {
            # Handle WriteExtra fields - skip if not enabled
            if ($key -in @("_Triggers", "_Source", "_FileNameExists", "_CommandExists")) {
                if (-not $WriteExtra) { continue }
            }
            
            $value = $appHashtable[$key]
            # The values are already properly formatted with quotes where needed
            $content += "$key=$value"
        }
        $content += ""
    }
    
    # Write to file
    $content | Out-File -FilePath $FilePath -Encoding UTF8
}

# Function to scan startup registry entries
function Get-StartupRegistry {
    [CmdletBinding()]
    param()
    
    $Registry = @()
    
    # Registry keys to check
    $registryKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServices",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunServicesOnce"
    )
    
    foreach ($key in $registryKeys) {
        try {
            $entries = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($entries) {
                $properties = $entries.PSObject.Properties | Where-Object {
                    $_.Name -notmatch '^PS' -and $_.Value -and $_.Value -notmatch '^$'
                }
                
                foreach ($property in $properties) {
                    $Registry += [PSCustomObject]@{
                        Name        = $property.Name
                        Command     = $property.Value
                        RegistryKey = $key
                        Type        = "StartupRegistry"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not access registry key: $key"
        }
    }
    
    return $Registry
}

# Function to scan logon scripts
function Get-StartupScripts {
    [CmdletBinding()]
    param()
    
    $logonScripts = @()
    
    # Group Policy logon scripts
    $gpoPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Logon",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Logon"
    )
    
    foreach ($path in $gpoPaths) {
        try {
            $scripts = Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | Where-Object {
                $_.PSChildName -eq "Script"
            }
            
            foreach ($script in $scripts) {
                $scriptPath = Get-ItemProperty -Path $script.PSPath -Name "Script" -ErrorAction SilentlyContinue
                if ($scriptPath.Script) {
                    $logonScripts += [PSCustomObject]@{
                        Name        = "GPO_$($script.PSChildName)"
                        Command     = $scriptPath.Script
                        RegistryKey = $script.PSPath
                        Type        = "LogonScript"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not access GPO scripts: $path"
        }
    }
    
    # User logon scripts from registry
    $userLogonScripts = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Logon",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Logon"
    )
    
    foreach ($path in $userLogonScripts) {
        try {
            $script = Get-ItemProperty -Path $path -Name "LogonScript" -ErrorAction SilentlyContinue
            if ($script.LogonScript) {
                $logonScripts += [PSCustomObject]@{
                    Name        = "UserLogonScript"
                    Command     = $script.LogonScript
                    RegistryKey = $path
                    Type        = "LogonScript"
                }
            }
        }
        catch {
            Write-Verbose "Could not access user logon scripts: $path"
        }
    }
    
    return $logonScripts
}

# Function to convert startup entry to ApplicationEntry object
function Convert-StartupEntryToApplicationEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$StartupEntry
    )
    
    try {
        $executablePath = ""
        $arguments = ""
        
        # Parse command line to extract executable and arguments using our helper function
        if ($StartupEntry.Command) {
            $command = $StartupEntry.Command.Trim()
            try {
                Write-Verbose "Will try to parse command line for startup entry $command"
                $parsedCommand = Parse-CommandLine -CommandLine $command
                $executablePath = if ($parsedCommand[0] -is [System.IO.FileInfo]) { $parsedCommand[0].FullName } else { $parsedCommand[0] }
                $arguments = $parsedCommand[1] -join " "
            }
            catch {
                Write-Verbose "Failed to parse command line: $command - $($_.Exception.Message)"
                return $null
            }
        }
        elseif ($StartupEntry.Path) {
            $executablePath = $StartupEntry.Path
        }
        
        # Skip if no executable found
        if (-not $executablePath) {
            return $null
        }
        
        # Expand environment variables
        $executablePath = [Environment]::ExpandEnvironmentVariables($executablePath)
        
        # Verify executable exists
        if (-not [System.IO.File]::Exists($executablePath)) {
            Write-Verbose "Executable not found: $executablePath"
            return $null
        }
        
        # Create application entry using ApplicationEntry::new() with default settings
        $entry = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
        
        # Set the specific properties for this startup entry
        $entry.FileName = $executablePath
        # Use Executable class to handle command line formatting
        $executable = [Executable]::new($executablePath, $arguments)
        $entry.Command = $executable.ToString()
        $entry.WorkingDirectory = Format-PathWithQuotes -Path ([System.IO.Path]::GetDirectoryName($executablePath)) -ForceQuotes
        $entry.Triggers = "Logon"
        
        return $entry
    }
    catch {
        Write-Verbose "Error converting startup entry: $($_.Exception.Message)"
        return $null
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

function Load-StartupTasks {
    <#
    .SYNOPSIS
        Loads all startup-related tasks and applications.
    .DESCRIPTION
        Scans scheduled tasks that are triggered on Boot or Logon and are enabled.
        Also scans startup files, registry entries, and logon scripts if specified.
        This function forces -Triggers Boot,Logon and -EnabledOnly parameters internally.
        If -Disable is specified, tasks are disabled directly during loading.
    .OUTPUTS
        [ApplicationEntry[]]
    #>
    Write-Host "Loading startup tasks..." -ForegroundColor Blue
    # Initialize applications array
    $validApplications = @()
    
    # Process scheduled tasks if -StartupTasks is specified
    if ($Tasks) {
        Write-Host "Loading startup tasks (Boot/Logon triggers, enabled only)..." -ForegroundColor Blue
        
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
        $taskXmlFiles = Get-TaskXmlFiles -TaskPaths $taskPaths
        Write-Host "Found $($taskXmlFiles.Count) total task files" -ForegroundColor Yellow
        
        # Force specific triggers and enabled only
        $forcedTriggers = @("Boot", "Logon")
        $forcedEnabledOnly = $true
        
        Write-Host "Filtering tasks to only include triggers: $($forcedTriggers -join ', ')" -ForegroundColor Cyan
        Write-Host "Filtering tasks to only include enabled tasks" -ForegroundColor Cyan
        
        if ($Disable) {
            Write-Host "WARNING: Tasks will be stopped and disabled after successful conversion!" -ForegroundColor Red
            Write-Host "This action cannot be undone automatically. Use with caution." -ForegroundColor Red
        }
        
        # Convert tasks to application format
        $processedCount = 0
        $disabledCount = 0
        $failedDisableCount = 0
    
        foreach ($xmlFile in $taskXmlFiles) {
            $processedCount++
            if ($processedCount % 50 -eq 0) {
                Write-Host "Processed $processedCount of $($taskXmlFiles.Count) task files..." -ForegroundColor Gray
            }
        
            try {
                # Parse the XML file
                $xmlContent = Get-Content $xmlFile.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $xmlContent) { continue }
            
                # Create XML object
                $xml = [xml]$xmlContent
            
                # Extract task path from the XML file path
                $taskPath = $xmlFile.FullName
                if ($taskPath -like "*\System32\Tasks\*") {
                    $taskPath = $taskPath -replace ".*\\System32\\Tasks", ""
                }
                elseif ($taskPath -like "*\Tasks\*") {
                    $taskPath = $taskPath -replace ".*\\Tasks", ""
                }
                elseif ($taskPath -like "*\ScheduledJobs\*") {
                    $taskPath = $taskPath -replace ".*\\ScheduledJobs", ""
                }
            
                # Check if task should be ignored
                if (Test-TaskShouldBeIgnored -TaskPath $taskPath -IgnorePatterns $Ignore) {
                    continue
                }
            
                # Check if task is enabled (if EnabledOnly is specified)
                if ($forcedEnabledOnly -and -not (Test-TaskIsEnabled -Xml $xml)) {
                    continue
                }
            
                Write-Verbose "[Load-StartupTasks] Will try to get executable path and arguments from task $($xmlFile.FullName)"
                $executables = Get-ExecutablePathAndArgsFromXml -Xml $xml
                
                # Skip if no executables found
                if ($executables.Count -eq 0) { continue }
                
                # Use the first executable for now (we could create multiple ApplicationEntry objects if needed)
                $primaryExecutable = $executables[0]
                $executablePath = $primaryExecutable.Path
                $arguments = $primaryExecutable.Arguments
            
                # Verify executable exists
                if (-not [System.IO.File]::Exists($executablePath)) { continue }
            
                # Extract working directory
                $workingDirectory = Get-WorkingDirectory -ExecutablePath $executablePath
            
                # Extract triggers
                $taskTriggers = Get-TriggersFromXml -Xml $xml
            
                # Check if task has specified triggers
                if ($forcedTriggers.Count -gt 0) {
                    $hasMatchingTrigger = $false
                    foreach ($trigger in $taskTriggers) {
                        if ($forcedTriggers -contains $trigger) {
                            $hasMatchingTrigger = $true
                            break
                        }
                    }
                    if (-not $hasMatchingTrigger) { continue }
                }
            
                # Create ApplicationEntry object with default settings
                $app = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
            
                # Set basic properties
                $app.FileName = [System.IO.Path]::GetFileName($executablePath)
                $app.Source = "Scheduled Task: $($xmlFile.FullName)"
                # Use Executable class to handle command line formatting
                $executable = [Executable]::new($executablePath, $arguments)
                $app.Command = $executable.ToString()
                $app.WorkingDirectory = Format-PathWithQuotes -Path $workingDirectory -ForceQuotes
            
                # Set triggers
                if ($taskTriggers.Count -gt 0) {
                    $app.Triggers = $taskTriggers -join ","
                }
                else {
                    $app.Triggers = ""
                }
            
                # Apply application-specific overrides if they exist
                if ($Script:AppOverrides.ContainsKey($executablePath)) {
                    $app.ApplyOverrides($Script:AppOverrides[$executablePath])
                }
            
                $validApplications += $app
            
                # Disable task if requested
                if ($Disable) {
                    $taskName = $xmlFile.Name
                    if (Disable-SingleScheduledTask -TaskName $taskName -TaskPath $taskPath) {
                        $disabledCount++
                    }
                    else {
                        $failedDisableCount++
                    }
                }
            }
            catch {
                Write-Verbose "Error processing task $($xmlFile.Name): $($_.Exception.Message)"
            }
        }
    
        Write-Host "Startup tasks processing summary:" -ForegroundColor Yellow
        Write-Host "  Total task files processed: $processedCount" -ForegroundColor White
        Write-Host "  Valid startup applications found: $($validApplications.Count)" -ForegroundColor White
    
        if ($Disable) {
            Write-Host "  Tasks successfully disabled: $disabledCount" -ForegroundColor Green
            Write-Host "  Tasks failed to disable: $failedDisableCount" -ForegroundColor Red
        }
    }
    Write-Host "Loaded $($validApplications.Count) startup tasks" -ForegroundColor Green
    return $validApplications
}

function Load-StartupScriptsFiles {
    <#
    .SYNOPSIS
        Returns a list of ApplicationEntry objects for all scripts set to run at user logon via Group Policy (Logon Scripts).
    .DESCRIPTION
        Scans the standard locations for logon scripts defined in Group Policy for all users and returns a list of ApplicationEntry objects for each found script.
    .OUTPUTS
        [ApplicationEntry[]]
    #>
    Write-Host "Loading startup scripts..." -ForegroundColor Blue
    
    # Initialize counters for disable mode
    $disabledCount = 0
    $failedDisableCount = 0
    
    if ($Disable) {
        Write-Host "WARNING: Startup scripts will be moved to AutorunsDisabled\ subfolder after successful conversion!" -ForegroundColor Red
        Write-Host "This action cannot be undone automatically. Use with caution." -ForegroundColor Red
    }
    
    $entries = @()

    # Common locations for logon scripts
    $scriptDirs = @(
        "$env:WINDIR\System32\GroupPolicy\User\Scripts\Logon",
        "$env:WINDIR\System32\GroupPolicy\Machine\Scripts\Startup"
    )

    foreach ($dir in $scriptDirs) {
        if (Test-Path $dir) {
            $iniPath = Join-Path $dir "scripts.ini"
            Write-Verbose "[Load-StartupScriptsFiles] Processing $($iniPath)"
            if (Test-Path $iniPath) {
                # Parse scripts.ini for script file names
                $lines = Get-Content $iniPath
                foreach ($line in $lines) {
                    if ($line -match '^\s*Script\s*=\s*(.+)$') {
                        $scriptFile = $matches[1].Trim()
                        $scriptPath = Join-Path $dir $scriptFile
                        if (Test-Path $scriptPath) {
                            # Check if script should be ignored
                            if (Test-ItemShouldBeIgnored -ItemName $scriptFile -IgnorePatterns $Ignore) {
                                Write-Warning "[Load-StartupScriptsFiles] Ignoring script due to pattern match: $scriptFile"
                                continue
                            }
                            $entry = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
                            $entry.FileName = $scriptPath
                            $entry.Source = "Script File: $scriptPath"
                            # Use Executable class to handle command line formatting
                            $executable = [Executable]::new($scriptPath, "")
                            $entry.Command = $executable.ToString()
                            $entry.WorkingDirectory = Format-PathWithQuotes -Path ([System.IO.Path]::GetDirectoryName($scriptPath)) -ForceQuotes
                            $entry.Triggers = "Logon"
                            $entries += $entry
                            
                            # Disable startup script if requested
                            if ($Disable) {
                                if (Disable-SingleStartupFile -FilePath $scriptPath) {
                                    $disabledCount++
                                }
                                else {
                                    $failedDisableCount++
                                }
                            }
                        }
                    }
                }
            }
            # Also enumerate all .bat, .cmd, .ps1, .vbs files in the directory
            $scriptFiles = Get-ChildItem -Path $dir -File -Include *.bat, *.cmd, *.ps1, *.vbs -ErrorAction SilentlyContinue
            foreach ($file in $scriptFiles) {
                # Check if script should be ignored
                if (Test-ItemShouldBeIgnored -ItemName $file.Name -IgnorePatterns $Ignore) {
                    Write-Warning "[Load-StartupScriptsFiles] Ignoring script due to pattern match: $($file.Name)"
                    continue
                }
                
                $entry = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
                $entry.FileName = $file.FullName
                $entry.Source = "Script File: $($file.FullName)"
                # Use Executable class to handle command line formatting
                $executable = [Executable]::new($file.FullName, "")
                $entry.Command = $executable.ToString()
                $entry.WorkingDirectory = Format-PathWithQuotes -Path $file.DirectoryName -ForceQuotes
                $entry.Triggers = if ($dir -like "*Startup") { "Boot" } else { "Logon" }
                $entries += $entry
                
                # Disable startup script if requested
                if ($Disable) {
                    if (Disable-SingleStartupFile -FilePath $file.FullName) {
                        $disabledCount++
                    }
                    else {
                        $failedDisableCount++
                    }
                }
            }
        }
    }
    Write-Host "Loaded $($entries.Count) startup scripts" -ForegroundColor Green
    
    if ($Disable) {
        Write-Host "  Startup scripts successfully disabled: $disabledCount" -ForegroundColor Green
        Write-Host "  Startup scripts failed to disable: $failedDisableCount" -ForegroundColor Red
    }
    
    return $entries
}
function Load-StartupRegistry {
    <#
    .SYNOPSIS
        Returns a list of ApplicationEntry objects for all programs set to run at Windows startup via registry.
    .DESCRIPTION
        Scans the standard Run and RunOnce registry keys for both the current user and all users,
        and returns a list of ApplicationEntry objects for each found entry.
    .OUTPUTS
        [ApplicationEntry[]]
    #>
    Write-Host "Loading startup registry entries..." -ForegroundColor Blue
    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    )

    $entries = @()

    foreach ($key in $runKeys) {
        if (Test-Path $key) {
            $values = Get-ItemProperty -Path $key | Select-Object -Property * -ExcludeProperty PSPath, PSParentPath, PSChildName, PSDrive, PSProvider
            foreach ($property in $values.PSObject.Properties) {
                $name = $property.Name
                $commandLine = $property.Value
                
                # Check if registry entry should be ignored
                if (Test-ItemShouldBeIgnored -ItemName $name -IgnorePatterns $Ignore) {
                    Write-Warning "[Load-StartupRegistry] Ignoring registry entry due to pattern match: $name"
                    continue
                }

                # Try to extract the executable path and arguments using our helper function
                try {
                    Write-Verbose "Will try to parse command line for Startup Registry $($name)"
                    $parsedCommand = Parse-CommandLine -CommandLine $commandLine
                    $exePath = if ($parsedCommand[0] -is [System.IO.FileInfo]) { $parsedCommand[0].FullName } else { $parsedCommand[0] }
                    $arguments = $parsedCommand[1] -join " "
                    $workingDir = [System.IO.Path]::GetDirectoryName($exePath)

                    # Create entry with default settings first, then overwrite with actual values
                    $entry = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
                    $entry.FileName = $exePath
                    $entry.Source = "Registry: $key\$name"
                    # Use Executable class to handle command line formatting
                    $executable = [Executable]::new($exePath, $arguments)
                    $entry.Command = $executable.ToString()
                    $entry.Triggers = "Logon"
                    $entry.CrashDelay = 60
                    $entries += $entry
                }
                catch {
                    Write-Verbose "Failed to parse command line: $commandLine - $($_.Exception.Message)"
                    continue
                }
            }
        }
    }
    Write-Host "Loaded $($entries.Count) startup registry entries" -ForegroundColor Green
    return $entries
}

function Load-StartupFiles {
    <#
    .SYNOPSIS
        Returns a list of ApplicationEntry objects for all files in the user's and system's Startup folders.
    .DESCRIPTION
        Scans both the current user's and the common (all users) Startup folders for .lnk, .exe, .bat, and .cmd files,
        and returns a list of ApplicationEntry objects for each found file.
    .OUTPUTS
        [ApplicationEntry[]]
    #>
    Write-Host "Loading startup files..." -ForegroundColor Blue
    
    # Initialize counters for disable mode
    $disabledCount = 0
    $failedDisableCount = 0
    
    if ($Disable) {
        Write-Host "WARNING: Startup files will be moved to AutorunsDisabled\ subfolder after successful conversion!" -ForegroundColor Red
        Write-Host "This action cannot be undone automatically. Use with caution." -ForegroundColor Red
    }
    
    $startupFolders = @(
        [Environment]::GetFolderPath("Startup"),
        [Environment]::GetFolderPath("CommonStartup")
    ) | Where-Object { $_ -and (Test-Path $_) }

    $f = @()
    foreach ($folder in $startupFolders) {
        Write-Verbose "[Load-StartupFiles] Processing $($folder)"
        $folderFiles = Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue
        Write-Verbose "[Load-StartupFiles] Found $($folderFiles.Count) files in $($folder)"
        $f += $folderFiles
    }

    $entries = @()
    foreach ($file in $f) {
        Write-Verbose "[Load-StartupFiles] Processing $($file.FullName)"
        
        # Check if file should be ignored
        if (Test-ItemShouldBeIgnored -ItemName $file.Name -IgnorePatterns $Ignore) {
            Write-Warning "[Load-StartupFiles] Ignoring file due to pattern match: $($file.Name)"
            continue
        }
        
        $targetPath = $null
        $arguments = ""
        $workingDir = ""

        if ($file.Extension -ieq ".lnk") {
            # Use WScript.Shell to resolve shortcut target
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($file.FullName)
            $targetPath = $shortcut.TargetPath
            $arguments = $shortcut.Arguments
            $workingDir = $shortcut.WorkingDirectory
        }
        else {
            $targetPath = $file.FullName
            $workingDir = [System.IO.Path]::GetDirectoryName($targetPath)
        }

        if (-not $targetPath -or -not (Test-Path $targetPath)) {
            Write-Verbose "[Load-StartupFiles] Skipping $($file.FullName) - target path not found"
            continue
        }

        $entry = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
        $entry.FileName = $targetPath
        $entry.Source = "Startup File: $($file.FullName)"
        # Use Executable class to handle command line formatting
        $executable = [Executable]::new($targetPath, $arguments)
        $entry.Command = $executable.ToString()
        # Ensure working directory is not empty before formatting
        if ([string]::IsNullOrWhiteSpace($workingDir)) {
            $workingDir = [System.IO.Path]::GetDirectoryName($targetPath)
        }
        $entry.WorkingDirectory = Format-PathWithQuotes -Path $workingDir -ForceQuotes
        $entry.Triggers = "Logon"
        $entries += $entry
        
        # Disable startup file if requested
        if ($Disable) {
            if (Disable-SingleStartupFile -FilePath $file.FullName) {
                $disabledCount++
            }
            else {
                $failedDisableCount++
            }
        }
    }
    
    Write-Host "Loaded $($entries.Count) startup files" -ForegroundColor Green
    
    if ($Disable) {
        Write-Host "  Startup files successfully disabled: $disabledCount" -ForegroundColor Green
        Write-Host "  Startup files failed to disable: $failedDisableCount" -ForegroundColor Red
    }
    
    return $entries
}

# Function to load startup scripts from Group Policy registry
function Load-StartupScriptsRegistry {
    <#
    .SYNOPSIS
        Returns a list of ApplicationEntry objects for Group Policy startup scripts found in the registry.
    .DESCRIPTION
        Scans the Group Policy Scripts registry keys for startup scripts and returns a list of ApplicationEntry objects.
    .OUTPUTS
        [ApplicationEntry[]]
    #>
    Write-Host "Loading Group Policy startup scripts from registry..." -ForegroundColor Blue
    
    $entries = @()
    
    # Define registry paths to scan for Group Policy scripts
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Startup",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Logon",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Startup",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Logon"
    )
    
    foreach ($registryPath in $registryPaths) {
        if (Test-Path $registryPath) {
            Write-Verbose "[Load-StartupScriptsRegistry] Processing registry path: $registryPath"
            
            # Get all subkeys (GPO entries)
            $gpoKeys = Get-ChildItem -Path $registryPath -ErrorAction SilentlyContinue
            
            foreach ($gpoKey in $gpoKeys) {
                Write-Verbose "[Load-StartupScriptsRegistry] Processing GPO key: $($gpoKey.Name)"
                
                # Get script entries within this GPO
                $scriptKeys = Get-ChildItem -Path $gpoKey.PSPath -ErrorAction SilentlyContinue
                
                foreach ($scriptKey in $scriptKeys) {
                    Write-Verbose "[Load-StartupScriptsRegistry] Processing script key: $($scriptKey.Name)"
                    
                    try {
                        # Get script properties using a safer approach
                        Write-Verbose "[Load-StartupScriptsRegistry] Getting properties for: $($scriptKey.PSPath)"
                        
                        # Use Get-Item to get the registry key, then access properties individually
                        $regKey = Get-Item -Path $scriptKey.PSPath -ErrorAction SilentlyContinue
                        if (-not $regKey) {
                            Write-Verbose "[Load-StartupScriptsRegistry] Could not get registry key"
                            continue
                        }
                        
                        # Get individual properties safely
                        $scriptPath = $regKey.GetValue("Script", $null)
                        $parameters = $regKey.GetValue("Parameters", $null)
                        $isPowershellValue = $regKey.GetValue("IsPowershell", $null)
                        
                        Write-Verbose "[Load-StartupScriptsRegistry] Script: $scriptPath"
                        Write-Verbose "[Load-StartupScriptsRegistry] Parameters: $parameters"
                        Write-Verbose "[Load-StartupScriptsRegistry] IsPowershell raw value: $isPowershellValue"
                        
                        if (-not $scriptPath) {
                            Write-Verbose "[Load-StartupScriptsRegistry] No script path found"
                            continue
                        }
                        
                        # Check if script should be ignored
                        $scriptFileName = [System.IO.Path]::GetFileName($scriptPath)
                        if (Test-ItemShouldBeIgnored -ItemName $scriptFileName -IgnorePatterns $Ignore) {
                            Write-Warning "[Load-StartupScriptsRegistry] Ignoring script due to pattern match: $scriptFileName"
                            continue
                        }
                        
                        # Handle IsPowershell property which might be stored as binary or DWORD
                        $isPowershell = $false
                        if ($isPowershellValue -ne $null) {
                            Write-Verbose "[Load-StartupScriptsRegistry] IsPowershell type: $($isPowershellValue.GetType().Name)"
                            Write-Verbose "[Load-StartupScriptsRegistry] IsPowershell value: $isPowershellValue"
                            
                            if ($isPowershellValue -is [byte[]]) {
                                # Convert binary array to boolean (first byte should be 1 for true)
                                $isPowershell = $isPowershellValue[0] -eq 1
                            }
                            else {
                                # Try to convert to boolean/int
                                $isPowershell = [bool]$isPowershellValue
                            }
                        }
                        Write-Verbose "[Load-StartupScriptsRegistry] Final IsPowershell: $isPowershell"
                            
                        Write-Verbose "[Load-StartupScriptsRegistry] Found script: $scriptPath"
                        Write-Verbose "[Load-StartupScriptsRegistry] Parameters: $parameters"
                        Write-Verbose "[Load-StartupScriptsRegistry] IsPowerShell: $isPowershell"
                            
                        # Skip if script path is empty or doesn't exist
                        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path $scriptPath)) {
                            Write-Verbose "[Load-StartupScriptsRegistry] Skipping $scriptPath - path not found"
                            continue
                        }
                            
                        # Determine the executable based on script type
                        if ($isPowershell) {
                            $executablePath = "powershell.exe"
                            $commandLine = "powershell.exe -ExecutionPolicy Bypass -File `"$scriptPath`""
                            if ($parameters) {
                                $commandLine += " $parameters"
                            }
                        }
                        else {
                            # For batch files or other scripts, use the script path directly
                            $executablePath = $scriptPath
                            $commandLine = $scriptPath
                            if ($parameters) {
                                $commandLine += " $parameters"
                            }
                        }
                            
                        # Create ApplicationEntry
                        $entry = [ApplicationEntry]::new(@{}, $Script:DefaultAppSettings)
                        $entry.FileName = $executablePath
                        $entry.Source = "Group Policy Script: $registryPath\$($gpoKey.PSChildName)\$($scriptKey.PSChildName)"
                            
                        # Use Executable class to handle command line formatting
                        $executable = [Executable]::new($executablePath, $parameters)
                        $entry.Command = $executable.ToString()
                            
                        # Set working directory to script directory
                        $workingDirectory = [System.IO.Path]::GetDirectoryName($scriptPath)
                        $entry.WorkingDirectory = Format-PathWithQuotes -Path $workingDirectory -ForceQuotes
                            
                        # Set trigger based on registry path
                        if ($registryPath -like "*\Startup*") {
                            $entry.Triggers = "Boot"
                        }
                        elseif ($registryPath -like "*\Logon*") {
                            $entry.Triggers = "Logon"
                        }
                            
                        $entries += $entry
                        Write-Verbose "[Load-StartupScriptsRegistry] Added script: $scriptPath"
                    }
                    catch {
                        Write-Verbose "[Load-StartupScriptsRegistry] Error processing script key $($scriptKey.Name): $($_.Exception.Message)"
                    }
                }
            }
        }
        else {
            Write-Verbose "[Load-StartupScriptsRegistry] Registry path not found: $registryPath"
        }
    }
    
    Write-Host "Loaded $($entries.Count) Group Policy startup scripts from registry" -ForegroundColor Green
    return $entries
}

# Function to deduplicate ApplicationEntry objects
function Deduplicate-ApplicationEntries {
    <#
    .SYNOPSIS
        Removes duplicate ApplicationEntry objects based on Command property.
    
    .DESCRIPTION
        Processes an array of ApplicationEntry objects and removes duplicates based on:
        - Command property (exact match)
        
        This function is called automatically when the -NoDuplicates flag is specified.
        By default, the script keeps all entries regardless of duplicates.
    
    .PARAMETER Applications
        Array of ApplicationEntry objects to deduplicate.
    

    
    .RETURNS
        [ApplicationEntry[]] Array of deduplicated ApplicationEntry objects.
    
    .EXAMPLE
        PS> $deduplicated = Deduplicate-ApplicationEntries -Applications $validApplications
        Returns: Array of unique ApplicationEntry objects
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ApplicationEntry[]]$Applications
    )
    
    $deduplicatedApplications = @()
    $processedExecutables = @{}
    $addedCount = 0
    
    foreach ($app in $Applications) {
        # Get command for deduplication - only use Command property
        $commandKey = $app.Command
        
        # Skip if already processed (duplicate command)
        if ($processedExecutables.ContainsKey($commandKey)) {
            Write-Verbose "Skipping duplicate Command: $commandKey"
            continue
        }
        

        
        $deduplicatedApplications += $app
        $processedExecutables[$commandKey] = $true
        
        Write-Verbose "Added: $($app.FileName)"
        $addedCount++
    }
    
    Write-Host "Added applications: $addedCount" -ForegroundColor Cyan
    return $deduplicatedApplications
}

# Function to disable a single startup file by moving it to AutorunsDisabled subfolder
function Disable-SingleStartupFile {
    <#
    .SYNOPSIS
        Disables a startup file by moving it to an AutorunsDisabled subfolder.
    
    .DESCRIPTION
        Moves the specified startup file to an AutorunsDisabled subfolder within the same directory,
        effectively disabling it from running at startup.
    
    .PARAMETER FilePath
        The full path to the startup file to disable.
    
    .RETURNS
        [bool] True if the file was successfully disabled, False otherwise.
    
    .EXAMPLE
        PS> Disable-SingleStartupFile -FilePath "C:\Users\User\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\example.lnk"
        Returns: True if the file was successfully moved to AutorunsDisabled subfolder
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    
    try {
        if (-not (Test-Path $FilePath)) {
            Write-Verbose "File not found: $FilePath"
            return $false
        }
        
        $fileInfo = Get-Item -Path $FilePath
        $directory = $fileInfo.DirectoryName
        $fileName = $fileInfo.Name
        
        # Create AutorunsDisabled subfolder if it doesn't exist
        $disabledFolder = Join-Path $directory "AutorunsDisabled"
        if (-not (Test-Path $disabledFolder)) {
            New-Item -Path $disabledFolder -ItemType Directory -Force | Out-Null
            Write-Verbose "Created AutorunsDisabled folder: $disabledFolder"
        }
        
        # Move the file to the disabled folder
        $disabledPath = Join-Path $disabledFolder $fileName
        Move-Item -Path $FilePath -Destination $disabledPath -Force
        
        Write-Verbose "Successfully disabled startup file: $fileName -> $disabledPath"
        return $true
    }
    catch {
        Write-Verbose "Failed to disable startup file $FilePath : $($_.Exception.Message)"
        return $false
    }
}



# Main script logic
try {
    # Get command line, handle empty case when run from .cmd file
    $commandLine = $MyInvocation.Line
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        $commandLine = "Script executed from external source (e.g., .cmd file)"
    } else {
        $commandLine = $commandLine | Sanitize-CommandLine
    }
    Set-Variable -Name "commandLine" -Value $commandLine -Scope Global
    Write-Host "Script Command Line: $commandLine"

    Write-Host "Using output path: $OutputPath"
    

    
    # Show ignore patterns info if specified
    if ($Ignore.Count -gt 0) {
        Write-Host "Ignoring tasks matching patterns: $($Ignore -join ', ')" -ForegroundColor Cyan
    }
    

    
    # Load all startup-related tasks and applications
    $validApplications = @()

    if ($Merge) {
        # Create backup of existing file before merging
        if (Test-Path $OutputPath) {
            $backupPath = "$OutputPath.bak"
            try {
                Copy-Item -Path $OutputPath -Destination $backupPath -Force
                Write-Host "Created backup: $backupPath" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to create backup: $($_.Exception.Message)"
            }
        }
        
        $existingData = Read-ExistingIniFile -FilePath $OutputPath
        if ($existingData -and $existingData.Applications) {
            $validApplications += $existingData.Applications
        }
    }
    
    if ($Tasks) {
        $validApplications += Load-StartupTasks
    }
    if ($Files) {
        $validApplications += Load-StartupFiles
    }
    if ($Registry) {
        $validApplications += Load-StartupRegistry
    }
    if ($Scripts) {
        $validApplications += Load-StartupScriptsFiles
        $validApplications += Load-StartupScriptsRegistry
    }

    # If no startup parameters are specified, no applications will be loaded

    
    # Deduplicate application entries only if -NoDuplicates flag is specified
    if ($NoDuplicates) {
        Write-Host "Deduplicating application entries..." -ForegroundColor Cyan
        $applications = Deduplicate-ApplicationEntries -Applications $validApplications
    } else {
        Write-Host "Keeping all application entries (including duplicates)..." -ForegroundColor Cyan
        $applications = $validApplications
    }
    
    # Use the full command line (including parameters) used to invoke this script for documentation
    $Script:GeneralSettings._GeneratorCommand = $global:commandLine
    Write-Host "GeneratorCommand: $($Script:GeneralSettings._GeneratorCommand)"
    
    # Handle merge mode - combine existing and new applications
    $finalApplications = $applications
    $finalGeneralSettings = $Script:GeneralSettings.Clone()
    
    if ($Merge -and $existingData -and $existingData.Applications.Count -gt 0) {
        Write-Host "`nMerging with existing applications..." -ForegroundColor Cyan
        
        # Use existing general settings but update GeneratorCommand
        $finalGeneralSettings = $existingData.GeneralSettings.Clone()
        $finalGeneralSettings._GeneratorCommand = $Script:GeneralSettings._GeneratorCommand
        
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
    
    # Clean up triggers for all applications (remove duplicates)
    foreach ($app in $finalApplications) {
        $app.CleanupTriggers()
    }
    
    # Write INI file using configured general settings
    Write-IniContent -FilePath $OutputPath -GeneralSettings $finalGeneralSettings -Applications $finalApplications -WriteExtra $WriteExtra
    
    # Validate the generated INI file
    Validate-IniContent -FilePath $OutputPath
    
    if ($Merge) {
        Write-Host "Successfully merged INI file: $OutputPath" -ForegroundColor Green
        Write-Host "New applications added: $($applications.Count)" -ForegroundColor Yellow
        Write-Host "Total applications in file: $($finalApplications.Count)" -ForegroundColor Yellow
    }
    else {
        Write-Host "Successfully created INI file: $OutputPath" -ForegroundColor Green
        Write-Host "Total applications added: $($applications.Count)" -ForegroundColor Yellow
    }
    
    if ($NoDuplicates) {
        Write-Host "Deduplication was performed to remove duplicate entries." -ForegroundColor Green
    } else {
        Write-Host "All entries were kept (including duplicates)." -ForegroundColor Green
    }
    

    
    # Show summary
    Show-ApplicationSummary -Applications $applications
    
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    # exit 1
}