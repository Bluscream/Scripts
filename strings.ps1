param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Paths,
    
    [Parameter(Mandatory = $false)]
    [switch]$CommandLine,
    
    [Parameter(Mandatory = $false)]
    [int]$MinLength = 4,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxLength = 255,
    
    [Parameter(Mandatory = $false)]
    [int]$Threads = 4
)

# Define regex patterns for command-line filtering (in main scope for display)
Set-Variable -Name commandLineRegex -Value '^[/-]' -Scope Script
Set-Variable -Name commandLineAllowedCharsRegex -Value '^[a-zA-Z0-9/_:=@-]+$' -Scope Script

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to sanitize filename for use in path
function Get-SafeFileName {
    param([string]$Path)
    return $Path -replace '[\\/:*?"<>|]', '_'
}

# Function to filter strings based on criteria
function Filter-Strings {
    param(
        [string[]]$Strings,
        [bool]$CommandLineOnly = $false,
        [int]$MinLength = 4,
        [int]$MaxLength = 255
    )
    
    if ($CommandLineOnly) {
        return $Strings | Where-Object { 
            $_ -match $CommandLineRegex -and $_.Length -ge $MinLength -and $_.Length -le $MaxLength -and $_ -match $CommandLineAllowedCharsRegex
        }
    }
    else {
        return $Strings | Where-Object { 
            $_.Length -ge $MinLength -and $_.Length -le $MaxLength
        }
    }
}

# Function to save strings to file
function Save-StringsToFile {
    param(
        [string[]]$Strings,
        [string]$OutputPath,
        [string]$FilePath,
        [bool]$CommandLineOnly = $false
    )
    
    if ($Strings.Count -gt 0) {
        # Sort strings alphabetically and remove duplicates
        $sortedStrings = $Strings | Sort-Object -Unique
        $sortedStrings | Out-File -FilePath $OutputPath -Encoding UTF8
        
        $mode = if ($CommandLineOnly) { "command-line" } else { "" }
        Write-ColorOutput "✓ Extracted $($sortedStrings.Count) $mode strings from: $FilePath" "Green"
        return $true
    }
    return $false
}

# Function to extract strings from a file
function Extract-Strings {
    param(
        [string]$FilePath,
        [string]$OutputPath,
        [bool]$CommandLineOnly = $false,
        [int]$MinLength = 4,
        [int]$MaxLength = 255
    )
    

    
    try {
        # Create output directory if it doesn't exist
        $outputDir = Split-Path $OutputPath -Parent
        if (!(Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        
        # Use strings.exe if available, otherwise use PowerShell to extract readable strings
        $stringsExe = Get-Command strings.exe -ErrorAction SilentlyContinue
        
        if ($stringsExe) {
            # Use strings.exe with common options
            $result = & strings.exe -n $MinLength -a $FilePath 2>$null
            if ($result) {
                $filteredStrings = Filter-Strings -Strings $result -CommandLineOnly $CommandLineOnly -MinLength $MinLength -MaxLength $MaxLength
                return Save-StringsToFile -Strings $filteredStrings -OutputPath $OutputPath -FilePath $FilePath -CommandLineOnly $CommandLineOnly
            }
        }
        else {
            # Fallback: Read file as bytes and extract printable strings
            try {
                $bytes = [System.IO.File]::ReadAllBytes($FilePath)
                $strings = @()
                $currentString = ""
                
                foreach ($byte in $bytes) {
                    if ($byte -ge 32 -and $byte -le 126) {
                        $currentString += [char]$byte
                    }
                    else {
                        if ($currentString.Length -ge $MinLength) {
                            $strings += $currentString
                        }
                        $currentString = ""
                    }
                }
                
                if ($currentString.Length -ge $MinLength) {
                    $strings += $currentString
                }
                
                if ($strings.Count -gt 0) {
                    $filteredStrings = Filter-Strings -Strings $strings -CommandLineOnly $CommandLineOnly -MinLength $MinLength -MaxLength $MaxLength
                    return Save-StringsToFile -Strings $filteredStrings -OutputPath $OutputPath -FilePath $FilePath -CommandLineOnly $CommandLineOnly
                }
            }
            catch {
                Write-ColorOutput "✗ Failed to read file: $FilePath" "Red"
            }
        }
        
        Write-ColorOutput "✗ No strings found in: $FilePath" "Yellow"
        return $false
    }
    catch {
        Write-ColorOutput "✗ Error processing: $FilePath - $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to process a single file
function Process-SingleFile {
    param(
        [string]$FilePath,
        [string]$OutputPath,
        [bool]$CommandLineOnly,
        [int]$MinLength,
        [int]$MaxLength
    )
    
    try {
        return Extract-Strings -FilePath $FilePath -OutputPath $OutputPath -CommandLineOnly $CommandLineOnly -MinLength $MinLength -MaxLength $MaxLength
    }
    catch {
        Write-ColorOutput "✗ Error processing: $FilePath - $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to process files in parallel using PowerShell 7+ ForEach-Object -Parallel
function Process-FilesParallel {
    param(
        [array]$Files,
        [string]$BaseOutputDir,
        [bool]$CommandLineOnly,
        [int]$MinLength,
        [int]$MaxLength,
        [int]$Threads = 4
    )
    
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Write-ColorOutput "Using PowerShell 7+ parallel processing with $Threads concurrent jobs..." "Cyan"
        
        $results = $Files | ForEach-Object -ThrottleLimit $Threads -Parallel {
            $file = $_
            $baseOutputDir = $using:BaseOutputDir
            $commandLineOnly = $using:CommandLineOnly
            $minLength = $using:MinLength
            $maxLength = $using:MaxLength
            
            $relativePath = $file.FullName.Substring($using:Paths[0].Length).TrimStart('\')
            $safeFileName = $relativePath -replace '[\\/:*?"<>|]', '_'
            $outputPath = Join-Path $baseOutputDir "$safeFileName.strings.txt"
            
            # Simple string extraction without complex function imports
            try {
                $stringsExe = Get-Command strings.exe -ErrorAction SilentlyContinue
                if ($stringsExe) {
                    $result = & strings.exe -n $minLength -a $file.FullName 2>$null
                    if ($result) {
                        if ($commandLineOnly) {
                            $result = $result | Where-Object { 
                                $_ -match '^[/-]' -and $_.Length -ge $minLength -and $_.Length -le $maxLength -and $_ -match '^[a-zA-Z0-9/_:=@-]+$'
                            }
                        }
                        else {
                            $result = $result | Where-Object { 
                                $_.Length -ge $minLength -and $_.Length -le $maxLength
                            }
                        }
                        
                        if ($result.Count -gt 0) {
                            $result = $result | Sort-Object -Unique
                            $result | Out-File -FilePath $outputPath -Encoding UTF8
                            return $true
                        }
                    }
                }
                return $false
            }
            catch {
                return $false
            }
        }
        
        return ($results | Where-Object { $_ -eq $true }).Count
    }
    else {
        Write-ColorOutput "PowerShell 7+ required for parallel processing. Falling back to sequential processing." "Yellow"
        return 0
    }
}

# Main script logic
try {
    
    Write-ColorOutput "Starting string extraction process..." "Cyan"
    if ($CommandLine) {
        Write-ColorOutput "Command-line mode enabled - filtering for strings matching regex: $commandLineRegex and allowed chars: $commandLineAllowedCharsRegex ($MinLength-$MaxLength chars)" "Yellow"
    }
    else {
        Write-ColorOutput "Length filtering enabled - strings between $MinLength and $MaxLength characters" "Yellow"
    }
    
    # Create base output directory
    $baseOutputDir = Join-Path $env:TEMP "strings"
    if (!(Test-Path $baseOutputDir)) {
        New-Item -ItemType Directory -Path $baseOutputDir -Force | Out-Null
        Write-ColorOutput "Created output directory: $baseOutputDir" "Cyan"
    }
    
    $processedFiles = 0
    $successfulExtractions = 0
    
    foreach ($path in $Paths) {
        if (Test-Path $path) {
            if (Test-Path $path -PathType Leaf) {
                # It's a file
                $fileInfo = Get-Item $path
                if ($fileInfo.Extension -match '\.(exe|dll)$') {
                    $processedFiles++
                    $safeFileName = Get-SafeFileName $fileInfo.FullName
                    $outputPath = Join-Path $baseOutputDir "$safeFileName.strings.txt"
                    
                    if (Extract-Strings -FilePath $fileInfo.FullName -OutputPath $outputPath -CommandLineOnly $CommandLine -MinLength $MinLength -MaxLength $MaxLength) {
                        $successfulExtractions++
                    }
                }
                else {
                    Write-ColorOutput "Skipping non-executable file: $path" "Yellow"
                }
            }
            else {
                # It's a directory, search recursively
                Write-ColorOutput "Searching directory: $path" "Cyan"
                
                $exeFiles = Get-ChildItem -Path $path -Recurse -Include "*.exe", "*.dll" -ErrorAction SilentlyContinue

                Write-ColorOutput "Found $($exeFiles.Count) executable files" "Cyan"
                
                if ($exeFiles.Count -gt 1 -and $Threads -gt 1) {
                    # Use parallel processing for multiple files
                    $successfulCount = Process-FilesParallel -Files $exeFiles -BaseOutputDir $baseOutputDir -CommandLineOnly $CommandLine -MinLength $MinLength -MaxLength $MaxLength -MaxConcurrency $Threads
                    $processedFiles += $exeFiles.Count
                    $successfulExtractions += $successfulCount
                }
                else {
                    # Process files sequentially
                    foreach ($file in $exeFiles) {
                        $processedFiles++
                        $relativePath = $file.FullName.Substring($path.Length).TrimStart('\')
                        $safeFileName = Get-SafeFileName $relativePath
                        $outputPath = Join-Path $baseOutputDir "$safeFileName.strings.txt"
                        
                        if (Extract-Strings -FilePath $file.FullName -OutputPath $outputPath -CommandLineOnly $CommandLine -MinLength $MinLength -MaxLength $MaxLength) {
                            $successfulExtractions++
                        }
                    }
                }
            }
        }
        else {
            Write-ColorOutput "✗ Path not found: $path" "Red"
        }
    }
    
    Write-ColorOutput "`nExtraction Summary:" "Cyan"
    Write-ColorOutput "  Total files processed: $processedFiles" "White"
    Write-ColorOutput "  Successful extractions: $successfulExtractions" "Green"
    Write-ColorOutput "  Output directory: $baseOutputDir" "Cyan"
    
    if ($successfulExtractions -gt 0) {
        Write-ColorOutput "`nString extraction completed successfully!" "Green"
        Write-ColorOutput "Check the output directory for extracted string files." "Cyan"
    }
    else {
        Write-ColorOutput "`nNo strings were extracted. Check if the files contain extractable strings." "Yellow"
    }
    
}
catch {
    Write-ColorOutput "✗ Script error: $($_.Exception.Message)" "Red"
    exit 1
}
