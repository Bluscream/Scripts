# PowerShell 7 script to find all shutdown.exe files using Everything CLI
# Requires Everything CLI to be installed and accessible

# Function to check if Everything CLI is available
function Test-EverythingCLI {
    try {
        $null = Get-Command "es" -ErrorAction Stop
        return $true
    }
    catch {
        Write-Error "Everything CLI (es) not found. Please install Everything CLI and ensure it's in your PATH."
        return $false
    }
}

# Function to find shutdown.exe files using Everything CLI
function Find-ShutdownFiles {
    try {
        # Use Everything CLI to search for shutdown.exe files
        # The search is case-insensitive and looks for exact filename match
        $results = & es -instance 1.5a -r "filename:^shutdown.exe$" | Where-Object { $_ -match '\.exe$' }
        
        if ($results) {
            Write-Host "Found shutdown.exe files:" -ForegroundColor Green
            Write-Host "=========================" -ForegroundColor Green
            
            $validPaths = @()
            foreach ($path in $results) {
                # Clean up the path and ensure it's properly formatted
                $cleanPath = $path.Trim()
                if (Test-Path $cleanPath) {
                    Write-Host $cleanPath -ForegroundColor Yellow
                    $validPaths += $cleanPath
                }
            }
            
            Write-Host "`nTotal files found: $($validPaths.Count)" -ForegroundColor Cyan
            return $validPaths
        }
        else {
            Write-Host "No shutdown.exe files found." -ForegroundColor Yellow
            return @()
        }
    }
    catch {
        Write-Error "Error searching for shutdown.exe files: $($_.Exception.Message)"
        return @()
    }
}



# Function to check if LockHunter is available
function Test-LockHunter {
    $lockHunterPath = "C:\Program Files\LockHunter\LockHunter.exe"
    return Test-Path $lockHunterPath
}

# Function to unlock and rename a single file using LockHunter
function Unlock-AndRenameFile {
    param([string]$FilePath)
    
    Write-Host "`nAttempting to unlock and rename: $FilePath" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    
    # Check if LockHunter is available
    if (-not (Test-LockHunter)) {
        Write-Host "  ERROR: LockHunter not found at C:\Program Files\LockHunter\LockHunter.exe" -ForegroundColor Red
        Write-Host "  Please install LockHunter and try again." -ForegroundColor Red
        return $false
    }
    
    try {
        Write-Host "  Opening parent folder..." -ForegroundColor Yellow
        $parentFolder = Split-Path $FilePath -Parent
        Start-Process explorer -ArgumentList "`"$parentFolder`""
        
        # Wait a moment for explorer to open
        Start-Sleep -Seconds 1
        
        Write-Host "  Using LockHunter to unlock file..." -ForegroundColor Yellow
        
        # Start LockHunter with the file path
        Start-Process -FilePath "C:\Program Files\LockHunter\LockHunter.exe" -ArgumentList "`"$FilePath`"" -Wait
        
        # Wait a moment for LockHunter to process
        Start-Sleep -Seconds 2
        
        # Try to rename the file
        $newPath = (Split-Path $FilePath -Parent) + "\shutdown_.exe"
        Rename-Item -Path $FilePath -NewName $newPath -Force -ErrorAction Stop
        
        if (Test-Path $newPath) {
            Write-Host "  SUCCESS: File renamed to shutdown_.exe!" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "  FAILED: File was not renamed successfully" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Main execution
Write-Host "Searching for shutdown.exe files using Everything CLI..." -ForegroundColor Blue

# Check if Everything CLI is available
if (Test-EverythingCLI) {
    $shutdownFiles = Find-ShutdownFiles
    
    if ($shutdownFiles.Count -gt 0) {
        Write-Host "`nStarting unlock and rename process..." -ForegroundColor Blue
        Write-Host "=====================================" -ForegroundColor Blue
        
        $successCount = 0
        $totalCount = $shutdownFiles.Count
        
        foreach ($file in $shutdownFiles) {
            if (Unlock-AndRenameFile -FilePath $file) {
                $successCount++
            }
        }
        
        Write-Host "`n" + "="*50 -ForegroundColor Cyan
        Write-Host "SUMMARY" -ForegroundColor Cyan
        Write-Host "="*50 -ForegroundColor Cyan
        Write-Host "Total files processed: $totalCount" -ForegroundColor White
        Write-Host "Successfully renamed: $successCount" -ForegroundColor Green
        Write-Host "Failed: $($totalCount - $successCount)" -ForegroundColor Red
        
        if ($successCount -gt 0) {
            Write-Host "`nSuccessfully renamed shutdown.exe files to shutdown_.exe!" -ForegroundColor Green
        }
    }
    else {
        Write-Host "No shutdown.exe files found to process." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Please install Everything CLI and try again." -ForegroundColor Red
    Write-Host "Download from: https://www.voidtools.com/downloads/" -ForegroundColor Red
}
