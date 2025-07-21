. "$PSScriptRoot/powershell/bluscream.ps1"

function Show-ProcessMemoryUsage {
    param(
        [Parameter(Mandatory = $true)]
        [Alias("Name")]
        [string]$ProcessName,
        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 2
    )

    while ($true) {
        $totalWorkingSet = Get-ProcessMemory -Name $ProcessName
        if ($totalWorkingSet -gt 0) {
            if ($totalWorkingSet -ge 1GB) {
                $usedGB = [math]::Round($totalWorkingSet / 1GB, 2)
                $msg = "$usedGB GB"
            } else {
                $usedMB = [math]::Round($totalWorkingSet / 1MB, 2)
                $msg = "$usedMB MB"
            }
            & banner.exe -Title "Used RAM by $ProcessName" -Message $msg -Time $($IntervalSeconds-1)
        } else {
            # & banner.exe -Title "Used RAM by $ProcessName" -Message "Process not running" -Time 1
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

Show-ProcessMemoryUsage -Name "discord" -IntervalSeconds 3
