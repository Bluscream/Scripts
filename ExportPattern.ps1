# SearchFiles.ps1
param(
    [Parameter(Mandatory=$true)]
    [string]$Folder,
    
    [Parameter(Mandatory=$true)]
    [string]$RegexPattern
)

Write-Host "Starting search script... 💫"
Write-Host "Searching in folder: $($Folder)"
Write-Host "Looking for pattern: $($RegexPattern)"

# Validate inputs
if (-not (Test-Path $Folder)) {
    Write-Host "❌ Oops! Folder '$($Folder)' doesn't exist!" -ForegroundColor Red
    throw "Folder '$Folder' does not exist!"
}
if ([string]::IsNullOrEmpty($RegexPattern)) {
    Write-Host "❌ Oops! Regex pattern can't be empty!" -ForegroundColor Red
    throw "Regex pattern cannot be empty!"
}

try {
    # Find all files recursively in the specified folder
    Write-Host "🔍 Searching for files..."
    $files = Get-ChildItem -Path $Folder -Recurse -File
    
    # Initialize array to store unique foundMatches
    $foundMatches = @()
    
    # Process each file
    foreach ($file in $files) {
        Write-Host "✨ Checking file: $($file.FullName)"
        try {
            # Read file content
            $content = Get-Content -Path $file.FullName -Raw
            
            # Find all foundMatches in current file
            $filefoundMatches = [regex]::matches($content, $RegexPattern)
            
            # Extract matched values and add to collection
            foreach ($match in $filefoundMatches) {
                $foundMatches += $match.Value
                Write-Host "🎯 Found match: $($match.Value)" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "⚠️ Could not read file $($file.FullName): $_" -ForegroundColor Yellow
        }
    }
    
    # Sort foundMatches alphabetically and remove duplicates
    Write-Host "📝 Processing foundMatches..."
    $uniqueSortedfoundMatches = $foundMatches | 
        Select-Object -Unique |
        Sort-Object
    
    # Save results to file
    Write-Host "💾 Saving results to results.txt..."
    $uniqueSortedfoundMatches | Out-File -FilePath ".\results.txt" -Encoding UTF8
    
    Write-Host "✅ Done! Results saved to results.txt" -ForegroundColor Green
}
catch {
    Write-Host "❌ An error occurred: $_" -ForegroundColor Red
}