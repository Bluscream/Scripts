# Get all scheduled tasks
$allTasks = Get-ScheduledTask

# Initialize empty array properly
$startupLoginTasks = @()  # This creates an actual array we can add to

foreach ($task in $allTasks) {
    foreach ($trigger in $task.Triggers) {
        if ($trigger.CimClass.CimClassName -like "*Startup*" -or 
            $trigger.CimClass.CimClassName -like "*Logon*") {
            $startupLoginTasks += ,$task  # Note the comma prefix here
            break
        }
    }
}

# Display found tasks before disabling
Write-Host "Found $($startupLoginTasks.Count) tasks with startup/login triggers:"
$startupLoginTasks | Select-Object TaskName, State

# Prompt for confirmation
$response = Read-Host "Do you want to disable these tasks? (yes/no)"
$confirmed = $response -ieq "yes" -or $response -ieq "y" -or $response -ieq "all"
if ($confirmed) {
    $tasks = $startupLoginTasks
    if ($response -ieq "all") {
        $tasks = $allTasks
    }
    foreach ($task in $tasks) {
        try {
            Stop-ScheduledTask -InputObject $task
            Disable-ScheduledTask -InputObject $task
            Write-Host "Disabled task: $($task.TaskName)"
        }
        catch {
            Write-Warning "Failed to disable task '$($task.TaskName)': $_"
        }
    }
}