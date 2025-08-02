param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    [string]$OutputFile = $null,
    [string]$MergedClassName = "MergedClass"
)

# Read the file
$content = Get-Content $InputFile -Raw

# Extract using statements
$usings = ($content | Select-String -Pattern '^using .+;' -AllMatches).Matches.Value | Select-Object -Unique

# Extract namespace (if any)
$namespaceMatch = [regex]::Match($content, 'namespace\s+([\w\.]+)')
$namespace = if ($namespaceMatch.Success) { $namespaceMatch.Groups[1].Value } else { $null }

# Extract all class bodies
$classPattern = '(?s)class\s+\w+\s*\{(.*?)\}'
$classMatches = [regex]::Matches($content, $classPattern)

$allMembers = @()
foreach ($match in $classMatches) {
    $body = $match.Groups[1].Value
    $allMembers += $body.Trim()
}

# Merge all members into one class
$mergedClass = "public class $MergedClassName\n{\n$($allMembers -join "`n")\n}"

# Compose the final file
$output = @()
if ($usings) { $output += $usings }
if ($namespace) {
    $output += "namespace $namespace {"
    $output += $mergedClass
    $output += "}"
} else {
    $output += $mergedClass
}

# Write to output file
if (-not $OutputFile) {
    $OutputFile = [System.IO.Path]::ChangeExtension($InputFile, ".merged.cs")
}
Set-Content -Path $OutputFile -Value ($output -join "`n")
Write-Host "Merged class written to $OutputFile" 