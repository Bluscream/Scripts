$vm = "Windows 11"

function Is-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Copy-GPUDriverFiles {
    param(
        [string]$vm
    )
    
    if (-not (Is-Admin)) {
        Write-Host "This PowerShell Script must be run with Administrative Privileges for this to work."
        return;
    }

    $systemPath = "C:\Windows\System32\"
    $driverPath = "C:\Windows\System32\DriverStore\FileRepository\"
    
    # do we need guest vm privs? enable it
    Get-VM -Name $vm | Get-VMIntegrationService | ? {-not($_.Enabled)} | Enable-VMIntegrationService -Verbose
    
    # aggregate and copy files to driverstore
    $localDriverFolder = ""
    Get-ChildItem $driverPath -recurse | Where-Object {$_.PSIsContainer -eq $true -and $_.Name -match "nv_dispi.inf_amd64_*"} | Sort-Object -Descending -Property LastWriteTime | select -First 1 |
    ForEach-Object {
        if ($localDriverFolder -eq "") {
            $localDriverFolder = $_.Name                                  
        }
    }

    Write-Host $localDriverFolder

    Get-ChildItem $driverPath$localDriverFolder -recurse | Where-Object {$_.PSIsContainer -eq $false} |
    Foreach-Object {
        $sourcePath = $_.FullName
        $destinationPath = $sourcePath -replace "^C\:\\Windows\\System32\\DriverStore\\","C:\Temp\System32\HostDriverStore\"
        Copy-VMFile $vm -SourcePath $sourcePath -DestinationPath $destinationPath -Force -CreateFullPath -FileSource Host
    }

    # get all files related to NV*.* in system32
    Get-ChildItem $systemPath  | Where-Object {$_.Name -like "NV*"} |
    ForEach-Object {
        $sourcePath = $_.FullName
        $destinationPath = $sourcePath -replace "^C\:\\Windows\\System32\\","C:\Temp\System32\"
        Copy-VMFile $vm -SourcePath $sourcePath -DestinationPath $destinationPath -Force -CreateFullPath -FileSource Host
    }

    Write-Host "Success! Please go to C:\Temp\System32\ and copy the files to C:\Windows\System32\ ."
}

function Set-GpuPartitioning {
    param(
        [string]$vm
    )

    $minVRAM = 1
    $maxVRAM = 8
    $optimalVRAM = 7
    $minRAM = 1Gb
    $maxRAM = 16GB

    Remove-VMGpuPartitionAdapter -VMName $vm
    Add-VMGpuPartitionAdapter -VMName $vm
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM $minVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionVRAM $maxVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionVRAM $optimalVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionEncode $minVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionEncode $maxVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionEncode $optimalVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionDecode $minVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionDecode $maxVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionDecode $optimalVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionCompute $minVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -MaxPartitionCompute $maxVRAM
    Set-VMGpuPartitionAdapter -VMName $vm -OptimalPartitionCompute $optimalVRAM
    Set-VM -GuestControlledCacheTypes $true -VMName $vm
    Set-VM -LowMemoryMappedIoSpace $minRAM -VMName $vm
    Set-VM -HighMemoryMappedIoSpace $maxRAM -VMName $vm
}



$skipSection = $false
$prompt = Read-Host "Do you want to skip the GPU/driver file copy section? (Y/N)"
if ($prompt -match '^(Y|y)') {
    Write-Host "Skipping GPU/driver file copy..."
    $skipSection = $true
}
if (-not $skipSection) {
    Copy-GPUDriverFiles $vm
}

$skipSection = $false
$prompt = Read-Host "Do you want to skip the GPU/driver partitioning section? (Y/N)"
if ($prompt -match '^(Y|y)') {
    Write-Host "Skipping GPU/driver partitioning..."
    $skipSection = $true
}

if (-not $skipSection) {
    Stop-VM -Name $vm -Force
    Set-GpuPartitioning $vm
}

Write-Host "Press any key to start the VM..."
[void][System.Console]::ReadKey($true)
Start-VM -Name $vm