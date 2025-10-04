param(
    [Parameter(Mandatory = $true)]
    [string]$File,
    
    [Parameter(Mandatory = $false)]
    [int]$Amount = 100,
    
    [Parameter(Mandatory = $true)]
    [string]$MoveTo,
    
    [Parameter(Mandatory = $false)]
    [string]$Names,
    
    [Parameter(Mandatory = $false)]
    [switch]$Reverse
)

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Validate input parameters
if (-not $Reverse) {
    if (-not (Test-Path $File)) {
        Write-ColorOutput "Error: Source file '$File' does not exist!" "Red"
        exit 1
    }
}

if (-not (Test-Path $MoveTo)) {
    Write-ColorOutput "Error: Move destination '$MoveTo' does not exist!" "Red"
    exit 1
}

# Get desktop path
$DesktopPath = [Environment]::GetFolderPath("Desktop")
Write-ColorOutput "Desktop path: $DesktopPath" "Cyan"

if ($Reverse) {
    # REVERSE MODE: Undo the desktop filling operation
    
    Write-ColorOutput "`nREVERSE MODE: Undoing desktop filling operation..." "Magenta"
    
    # Step 1: Remove copied files from desktop
    Write-ColorOutput "`nStep 1: Removing copied files from desktop..." "Yellow"
    
    $SourceFile = Get-Item $File
    $Extension = $SourceFile.Extension
    $BaseName = $SourceFile.BaseName
    
    # Read custom names if provided (for reverse lookup)
    $CustomNames = @()
    if ($Names -and (Test-Path $Names)) {
        try {
            $CustomNames = Get-Content -Path $Names | Where-Object { $_.Trim() -ne "" }
        }
        catch {
            Write-ColorOutput "Warning: Could not read names file for reverse operation" "Yellow"
        }
    }
    
    $RemovedCount = 0
    for ($i = 1; $i -le $Amount; $i++) {
        try {
            # Determine filename (same logic as forward operation)
            if ($CustomNames.Count -ge $i) {
                $FileName = $CustomNames[$i - 1]
                if (-not $FileName.EndsWith($Extension)) {
                    $FileName += $Extension
                }
            }
            else {
                $FileName = "${BaseName}_Copy_$i$Extension"
            }
            
            $FilePath = Join-Path $DesktopPath $FileName
            
            if (Test-Path $FilePath) {
                Remove-Item -Path $FilePath -Force
                Write-ColorOutput "Removed: $FileName" "Green"
                $RemovedCount++
            }
        }
        catch {
            Write-ColorOutput "Failed to remove copy $i`: $($_.Exception.Message)" "Red"
        }
    }
    
    # Step 2: Restore original files from MoveTo back to desktop
    Write-ColorOutput "`nStep 2: Restoring original files from '$MoveTo' to desktop..." "Yellow"
    
    $MovedFiles = Get-ChildItem -Path $MoveTo -File
    $RestoredCount = 0
    
    foreach ($file in $MovedFiles) {
        try {
            $destinationPath = Join-Path $DesktopPath $file.Name
            Move-Item -Path $file.FullName -Destination $destinationPath -Force
            Write-ColorOutput "Restored: $($file.Name)" "Green"
            $RestoredCount++
        }
        catch {
            Write-ColorOutput "Failed to restore '$($file.Name)': $($_.Exception.Message)" "Red"
        }
    }
    
    Write-ColorOutput "`nReverse operation completed!" "Green"
    Write-ColorOutput "Removed $RemovedCount copied files from desktop" "Cyan"
    Write-ColorOutput "Restored $RestoredCount original files to desktop" "Cyan"
}
else {
    # FORWARD MODE: Original desktop filling operation
    
    # Step 1: Move all files from desktop to MoveTo location
    Write-ColorOutput "`nStep 1: Moving files from desktop to '$MoveTo'..." "Yellow"

    $DesktopFiles = Get-ChildItem -Path $DesktopPath -File
    if ($DesktopFiles.Count -eq 0) {
        Write-ColorOutput "No files found on desktop to move." "Green"
    }
    else {
        Write-ColorOutput "Found $($DesktopFiles.Count) files on desktop to move." "Cyan"
        
        foreach ($file in $DesktopFiles) {
            try {
                $destinationPath = Join-Path $MoveTo $file.Name
                Move-Item -Path $file.FullName -Destination $destinationPath -Force
                Write-ColorOutput "Moved: $($file.Name)" "Green"
            }
            catch {
                Write-ColorOutput "Failed to move '$($file.Name)': $($_.Exception.Message)" "Red"
            }
        }
    }

    # Step 2: Read custom names if provided
    $CustomNames = @()
    if ($Names -and (Test-Path $Names)) {
        Write-ColorOutput "`nReading custom names from '$Names'..." "Yellow"
        try {
            $CustomNames = Get-Content -Path $Names | Where-Object { $_.Trim() -ne "" }
            Write-ColorOutput "Loaded $($CustomNames.Count) custom names." "Green"
        }
        catch {
            Write-ColorOutput "Error reading names file: $($_.Exception.Message)" "Red"
            Write-ColorOutput "Will use default naming pattern." "Yellow"
        }
    }

    # Step 3: Copy files to desktop
    Write-ColorOutput "`nStep 2: Copying $Amount copies of '$File' to desktop..." "Yellow"

    $SourceFile = Get-Item $File
    $Extension = $SourceFile.Extension
    $BaseName = $SourceFile.BaseName

    for ($i = 1; $i -le $Amount; $i++) {
        try {
            # Determine filename
            if ($CustomNames.Count -ge $i) {
                $NewFileName = $CustomNames[$i - 1]
                # Ensure the filename has the correct extension
                if (-not $NewFileName.EndsWith($Extension)) {
                    $NewFileName += $Extension
                }
            }
            else {
                $NewFileName = "${BaseName}_Copy_$i$Extension"
            }
            
            $DestinationPath = Join-Path $DesktopPath $NewFileName
            
            # Copy the file
            Copy-Item -Path $File -Destination $DestinationPath -Force
            Write-ColorOutput "Created: $NewFileName" "Green"
        }
        catch {
            Write-ColorOutput "Failed to create copy $i`: $($_.Exception.Message)" "Red"
        }
    }

    Write-ColorOutput "`nDesktop filling operation completed!" "Green"
    Write-ColorOutput "Moved $($DesktopFiles.Count) files to '$MoveTo'" "Cyan"
    Write-ColorOutput "Created $Amount copies of '$File' on desktop" "Cyan"
}
