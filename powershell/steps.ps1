# powershell/steps.ps1
# Provides reusable step model logic for scripts

# Import Bluscream helper functions (required for some step actions)
. "$PSScriptRoot/bluscream.ps1"

# Only create $possibleSteps if it is not already defined
if (-not (Get-Variable -Name possibleSteps -Scope Script -ErrorAction SilentlyContinue)) {
    $script:possibleSteps = @{}
}

# region Predefined Steps
if (-not $possibleSteps.ContainsKey("special")) {
    $possibleSteps["special"] = @{
        toast = @{
            Description = "Show a toast notification"
            Code = { Show-Toast -Message $Message -Title "Clean.ps1" }
        }
        shutdown = @{
            Description = "Shutdown the computer"
            Code = {
                try {
                    Stop-Computer -Force
                } catch {
                    Write-Host "[SPECIAL] Failed to shutdown: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        logout = @{
            Description = "Log out the current user"
            Code = { Logout-CurrentUser }
        }
        sleep = @{
            Description = "Put the computer to sleep"
            Code = { Sleep-Computer }
        }
        lock = @{
            Description = "Lock the workstation"
            Code = { Lock-Computer }
        }
        reboot = @{
            Description = "Reboot the computer"
            Code = {
                try {
                    Restart-Computer -Force
                } catch {
                    Write-Host "[SPECIAL] Failed to reboot: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        hibernate = @{
            Description = "Hibernate the computer"
            Code = { Hibernate-Computer }
        }
        pause = @{
            Description = "Pause script execution until user input"
            Code = { Pause "Paused by user request. Press any key to continue..." }
        }
        elevate = @{
            Description = "Rerun the script as administrator (UAC prompt)"
            Code = { Elevate-Self }
        }
        exit = @{
            Description = "Exit Script"
            Code = { exit }
        }
        powersaver = @{
            Description = "Set Windows power plan to Power Saver"
            Code      = { Set-PowerProfile -Profile powersaver }
        }
        balanced = @{
            Description = "Set Windows power plan to Balanced"
            Code      = { Set-PowerProfile -Profile balanced }
        }
        highperformance = @{
            Description = "Set Windows power plan to High Performance"
            Code      = { Set-PowerProfile -Profile highperformance }
        }
        waitaminute = @{
            Description = "Wait for 60 seconds"
            Code = { Start-Sleep -Seconds 60 }
        }
    }
}
# endregion Predefined Steps

function Expand-Steps {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Steps,
        [Parameter(Mandatory)]
        [string[]]$Actions
    )
    $actionsToRun = @()
    foreach ($action in $Actions) {
        switch ($action) {
            "all" {
                if ($Steps.ContainsKey("clean")) {
                    $actionsToRun += $Steps["clean"].Keys
                }
            }
            "default" {
                if ($Steps.ContainsKey("meta") -and $Steps["meta"].ContainsKey("default")) {
                    $actionsToRun += $Steps["meta"]["default"].Actions
                }
            }
            default {
                $actionsToRun += $action
            }
        }
    }
    # Remove duplicates and preserve order
    return $actionsToRun | Select-Object -Unique
}

function Run-Steps {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Steps,
        [Parameter(Mandatory)]
        [string[]]$ActionsToRun
    )
    $actionTable = @()
    $stepNum = 1
    foreach ($act in $ActionsToRun) {
        foreach ($category in $Steps.Keys) {
            if ($Steps[$category].ContainsKey($act)) {
                $desc = $Steps[$category][$act].Description
                $actionTable += [PSCustomObject]@{
                    Step = $stepNum
                    Code = $act
                    Description = $desc
                }
                $stepNum++
                break
            }
        }
    }
    $actionTable | Format-Table -AutoSize

    foreach ($act in $ActionsToRun) {
        $found = $false
        foreach ($category in $Steps.Keys) {
            if ($Steps[$category].ContainsKey($act)) {
                & $Steps[$category][$act].Code
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Host "Unknown action $act" -ForegroundColor Red
        }
    }
}

# Only export module members if running as a module (not dot-sourced as a script)
if ($MyInvocation.ScriptName -and ($MyInvocation.ScriptName -like '*.psm1')) {
    Export-ModuleMember -Function Expand-Steps,Run-Steps -Variable possibleSteps
} 