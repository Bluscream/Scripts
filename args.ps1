param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

# Check if the file exists
if (-not (Test-Path $FilePath)) {
    Write-Error "File not found: $FilePath"
    exit 1
}

# Get base filename without extension
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
$directory = [System.IO.Path]::GetDirectoryName($FilePath)

# Create paths for output files
$stringsOutput = Join-Path $directory ($baseName + ".strings")
$argsOutput = Join-Path $directory ($baseName + ".args")

try {
    # Extract strings using sysinternals strings.exe
    Write-Host "Extracting strings from $FilePath..."
    & "strings.exe" -a "$FilePath" | Set-Content -Path $stringsOutput
    
    # Extract arguments starting with '-' and sort alphabetically
    Write-Host "Extracting command line arguments..."
    $stringsContent = Get-Content -Path $stringsOutput
    $argsarr = @()
    
    foreach ($line in $stringsContent) {
        if ($line -match '^-[^\s]*') {
            $argsarr += $line.Trim()
        }
    }
    
    if ($argsarr.Count -gt 0) {
        $sortedArgs = $args | Sort-Object
        $sortedArgs | Set-Content -Path $argsOutput
    } else {
        Write-Warning "No command line arguments found"
        New-Item -ItemType File -Path $argsOutput | Out-Null
    }
    
    Write-Host "Processing complete:"
    Write-Host "Strings saved to: $stringsOutput"
    Write-Host "Arguments saved to: $argsOutput"
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}