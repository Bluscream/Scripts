param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Paths,
    
    [Parameter(Mandatory = $false)]
    [switch]$CommandLine,
    
    [Parameter(Mandatory = $false)]
    [int]$MinLength = 4,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxLength = 255
)

# Define regex patterns for command-line filtering (in main scope for display)
$commandLineRegex = '^[/-]'
$commandLineAllowedCharsRegex = '^[a-zA-Z0-9/_:=@-]+$'

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

# Function to extract strings from a file
function Extract-Strings {
    param(
        [string]$FilePath,
        [string]$OutputPath,
        [bool]$CommandLineOnly = $false,
        [int]$MinLength = 4,
        [int]$MaxLength = 255
    )
    
    # Define regex patterns for command-line filtering
    $commandLineRegex = '^[/-]'
    $commandLineAllowedCharsRegex = '^[a-zA-Z0-9/_:=@-]+$'
    
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
                if ($CommandLineOnly) {
                    # Filter for command-line strings (starting with / or - and MinLength-MaxLength chars, only alphanumeric + /, -, :, =, @)
                    $result = $result | Where-Object { 
                        $_ -match $commandLineRegex -and $_ -match $commandLineAllowedCharsRegex
                    }
                }
                $result = $result | Where-Object { 
                    $_.Length -ge $MinLength -and $_.Length -le $MaxLength
                }
                
                # Sort strings alphabetically and remove duplicates
                $result = $result | Sort-Object -Unique
                $result | Out-File -FilePath $OutputPath -Encoding UTF8
                Write-ColorOutput "✓ Extracted $($result.Count) strings from: $FilePath" "Green"
                return $true
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
                    if ($CommandLineOnly) {
                        # Filter for command-line strings (starting with / or - and MinLength-MaxLength chars, only alphanumeric + /, -, :, =, @)
                        $filteredStrings = $strings | Where-Object { 
                            $_ -match $commandLineRegex -and $_.Length -ge $MinLength -and $_.Length -le $MaxLength -and $_ -match $commandLineAllowedCharsRegex
                        }
                        if ($filteredStrings.Count -gt 0) {
                            # Sort strings alphabetically and remove duplicates
                            $filteredStrings = $filteredStrings | Sort-Object -Unique
                            $filteredStrings | Out-File -FilePath $OutputPath -Encoding UTF8
                            Write-ColorOutput "✓ Extracted $($filteredStrings.Count) command-line strings from: $FilePath" "Green"
                            return $true
                        }
                    }
                    else {
                        # Filter by length for regular mode
                        $filteredStrings = $strings | Where-Object { 
                            $_.Length -ge $MinLength -and $_.Length -le $MaxLength
                        }
                        if ($filteredStrings.Count -gt 0) {
                            # Sort strings alphabetically and remove duplicates
                            $filteredStrings = $filteredStrings | Sort-Object -Unique
                            $filteredStrings | Out-File -FilePath $OutputPath -Encoding UTF8
                            Write-ColorOutput "✓ Extracted $($filteredStrings.Count) strings from: $FilePath" "Green"
                            return $true
                        }
                    }
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
