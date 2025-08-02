param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,
    [string]$OutputFile,
    [switch]$Fix,
    [switch]$Sort
)

if (-not $OutputFile) {
    $OutputFile = $InputFile
}

function Get-Hash {
    param($str)
    $str = $str.Trim()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($str)
    $hash = $sha256.ComputeHash($bytes)
    return -join ($hash | ForEach-Object { "{0:x2}" -f $_ })
}
class Variable {
    [bool]$This
    [string]$Name
    [string]$Type
    [string]$DefaultValue
    Variable([string]$name, [string]$type, [string]$defaultValue) {
        $this.Name = $name
        $this.Type = $type
        if ($type -like "this *") {
            $this.This = $true
            # $this.Type = $this.Type.TrimStart("this ")
            $this.Type = $this.Type.Replace("this ", "")
        }
        $this.DefaultValue = $defaultValue
    }
}
class OccurencePosition {
    [int]$Line
    [int]$Column
    OccurencePosition([int]$line, [int]$column) {
        $this.Line = $line
        $this.Column = $column
    }
}
class Occurence {
    [OccurencePosition]$Start
    [OccurencePosition]$End
    [string]$Raw
    [string]$Body
    [string]$BodyHash
    Occurence([OccurencePosition]$start, [OccurencePosition]$end, [string]$body, [string]$raw) {
        $this.Start = $start
        $this.End = $end
        $this.Raw = $raw
        $this.Body = $body
        if ($body) {
            $this.BodyHash = Get-Hash $body
        }
    }
}
class Attribute {
    [string]$Name
    [string]$Value
    Attribute([string]$name, [string]$value) {
        $this.Name = $name
        $this.Value = $value
    }
}
class FunctionInfo {
    [string]$Declaration
    [string]$Name
    [string]$ReturnType
    [Variable[]]$Variables
    [Occurence[]]$Occurences
    [Attribute[]]$Attributes
    FunctionInfo([string]$declaration, [Occurence[]]$occurences, [Variable[]]$variables, [Attribute[]]$attributes, [string]$returnType) {
        $this.Declaration = $declaration
        if ($declaration -match '\b([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
            $this.Name = $Matches[1]
        }
        if ($returnType) {
            $this.ReturnType = $returnType
        } elseif ($declaration -match '^\s*public\s*static\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
            $this.ReturnType = $Matches[1]
        }
        $this.Occurences = $occurences
        $this.Variables = $variables
        $this.Attributes = $attributes
    }
}

function Test-FunctionDeclaration {
    param([string]$Line, [string[]]$Lines, [int]$Index)
    
    # Skip if it's a control flow statement
    if ($Line -match '^\s*(if|else|for|while|switch|foreach)\b') {
        return $false
    }
    
    # Skip if it's a class/struct/enum declaration
    if ($Line -match '^\s*(class|struct|enum|interface)\s+') {
        return $false
    }
    
    # Skip if it's a property
    if ($Line -match '^\s*[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s]*\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\{\s*get\s*;') {
        return $false
    }
    
    # Skip if it's a field declaration
    if ($Line -match '^\s*(?:public|private|protected|internal|static|const)?\s*[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s]*\s+[a-zA-Z_][a-zA-Z0-9_]*\s*;?\s*$') {
        # But only if it doesn't have parentheses (which would indicate a method)
        if ($Line -notmatch '\(') {
            return $false
        }
    }
    
    # More comprehensive function detection patterns
    $patterns = @(
        # Any line that contains a method name followed by parentheses
        '^\s*(?:\[[^\]]+\]\s*)*\s*(?:public|private|protected|internal|static|virtual|override|sealed|async|extern|unsafe|new)?\s*[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s\(\)]*\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\([^)]*\)\s*(?:\{|;|=>|$)',
        # DllImport methods
        '^\s*\[DllImport[^\]]*\]\s*public\s+extern\s+[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s\(\)]*\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\([^)]*\)\s*;',
        # Methods without access modifiers
        '^\s*[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s\(\)]*\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\([^)]*\)\s*(?:\{|;|=>)',
        # Multi-line function declarations (start of)
        '^\s*(?:\[[^\]]+\]\s*)*\s*(?:public|private|protected|internal|static|virtual|override|sealed|async|extern|unsafe|new)?\s*[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s\(\)]*\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\([^)]*$'
    )
    
    foreach ($pattern in $patterns) {
        if ($Line -match $pattern) {
            return $true
        }
    }
    
    return $false
}
function Parse-Attribute {
    param([string]$Line)
    if ($Line -match '^\s*\[([^\]]+)\s*\]\s*') {
        $attributeContent = $Matches[1].Trim()
        
        # Parse DllImport and other attributes with parameters
        if ($attributeContent -match '^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*(.+)\s*\)$') {
            $attributeName = $Matches[1]
            $attributeValue = $Matches[2].Trim()
            return [Attribute]::new($attributeName, $attributeValue)
        }
        # Parse simple attributes without parameters
        elseif ($attributeContent -match '^([A-Za-z_][A-Za-z0-9_]*)$') {
            $attributeName = $Matches[1]
            return [Attribute]::new($attributeName, "")
        }
    }
    return $null
}
function Parse-FunctionVariables {
    param([string]$MethodArgs)
    $variables = @()
    if ($MethodArgs -and $MethodArgs.Trim() -ne "") {
        $argList = $MethodArgs -split ','
        foreach ($arg in $argList) {
            $arg = $arg.Trim()
            # Match: [type] [name][ = default]
            if ($arg -match '^(?<type>[a-zA-Z_][a-zA-Z0-9_<>,\[\]\s\(\)]*)\s+(?<name>[a-zA-Z_][a-zA-Z0-9_]*)(\s*=\s*(?<default>.+))?$') {
                $type = $Matches['type'].Trim()
                $name = $Matches['name']
                $default = $Matches['default']
                $varObj = [Variable]::new($name, $type, $default)
                $variables += $varObj
            }
        }
    }
    return $variables
}
function Parse-Function {
    param([string[]]$Lines, [int]$StartIndex)
    
    $startLine = $StartIndex
    $declarationLines = @()
    $functionBodyLines = @()
    $parenCount = 0
    $braceCount = 0
    $foundOpeningBrace = $false
    $foundSemicolon = $false
    $foundArrow = $false
    $inFunctionBody = $false
    $declarationComplete = $false

    # Collect attribute lines above the function declaration, in correct order
    $attributeLines = @()
    $attrIdx = $startLine - 1
    while ($attrIdx -ge 0) {
        $line = $Lines[$attrIdx].Trim()
        if ($line -eq "") {
            $attrIdx--
            continue
        }
        if ($line.StartsWith('[')) {
            $attributeLines += $Lines[$attrIdx]
            $attrIdx--
        } else {
            break
        }
    }
    if ($attributeLines.Count -gt 1) {
        $attributeLines = $attributeLines | Select-Object -Reverse
    }

    # First, collect the complete function declaration
    for ($i = $StartIndex; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $declarationLines += $line
        
        # Count parentheses and braces
        $parenCount += ($line -split '\(').Count - 1
        $parenCount -= ($line -split '\)').Count - 1
        $braceCount += ($line -split '\{').Count - 1
        $braceCount -= ($line -split '\}').Count - 1
        
        # Check for function body indicators
        if ($line -match '\{') { $foundOpeningBrace = $true }
        if ($line -match ';') { $foundSemicolon = $true }
        if ($line -match '=>') { $foundArrow = $true }
        
        # If we found a complete declaration and body indicator, we're done with declaration
        if ($parenCount -eq 0 -and ($foundOpeningBrace -or $foundSemicolon -or $foundArrow)) {
            $declarationComplete = $true
            break
        }
    }
    
    # Extract function declaration
    $fullDeclaration = $declarationLines -join " "
    
    # Extract method name and arguments
    $returnType = $null
    if ($fullDeclaration -match '([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)') {
        $methodName = $Matches[1]
        $methodArgs = $Matches[2]
        $functionVariables = Parse-FunctionVariables -MethodArgs $methodArgs

        # Try to extract return type (the word before the method name)
        # This regex matches: [modifiers] returnType methodName(
        if ($fullDeclaration -match '(?:public|private|protected|internal|static|virtual|override|sealed|async|extern|unsafe|new|\s)*([a-zA-Z_][a-zA-Z0-9_<>,\[\]\s\(\)]*)\s+' + [regex]::Escape($methodName) + '\s*\(') {
            $returnType = $Matches[1].Trim()
        }
    }
    else {
        return $null
    }
    
    # Clean up the declaration to only include the method signature (without { and trimmed)
    if ($fullDeclaration -match '^(.*?)\s*\{') {
        # Function with braces - extract everything before the {
        $fullDeclaration = $Matches[1].Trim()
    }
    elseif ($fullDeclaration -match '^(.*?)\s*=>') {
        # Expression-bodied member - extract everything before the =>
        $fullDeclaration = $Matches[1].Trim()
    }
    elseif ($fullDeclaration -match '^(.*?)\s*;') {
        # Function ending with semicolon - extract everything before the ;
        $fullDeclaration = $Matches[1].Trim()
    }
    else {
        # Fallback - just trim the declaration
        $fullDeclaration = $fullDeclaration.Trim()
    }
    
    # Now collect the complete function body if it has one
    $functionEndLine = $i
    if ($foundOpeningBrace) {
        # Function has a body with braces, need to find the closing brace
        $braceCount = 0
        $inFunctionBody = $true
        
        for ($j = $i; $j -lt $Lines.Count; $j++) {
            $line = $Lines[$j]
            $functionBodyLines += $line
            
            $braceCount += ($line -split '\{').Count - 1
            $braceCount -= ($line -split '\}').Count - 1
            
            if ($braceCount -eq 0) {
                $functionEndLine = $j
                break
            }
        }
    }
    elseif ($foundArrow) {
        # Expression-bodied member, body is on the same line or next line
        $functionEndLine = $i
    }
    elseif ($foundSemicolon) {
        # Function ends with semicolon (like DllImport)
        $functionEndLine = $i
    }

    # Parse attributes
    $attributes = @()
    foreach ($attrLine in $attributeLines) {
        $attributes += Parse-Attribute -Line $attrLine
    }

    # Compose the full raw function text (attributes + declaration + body)
    $rawLines = @()
    if ($attributeLines.Count -gt 0) { $rawLines += $attributeLines }
    $rawLines += $declarationLines
    if ($functionBodyLines.Count -gt 0) {
        if ($functionBodyLines.Count -ge 2 -and $functionBodyLines[0] -eq $functionBodyLines[1]) {
            $functionBodyLines = $functionBodyLines[1..($functionBodyLines.Count-1)]
        }
        $rawLines += $functionBodyLines
    }
    $raw = $rawLines -join "`n"
    
    # Create occurrence with full function body
    $startPos = [OccurencePosition]::new($startLine + 1, 1)
    $endPos = [OccurencePosition]::new($functionEndLine + 1, $Lines[$functionEndLine].Length)
    $body = ($declarationLines + $functionBodyLines) -join "`n"
    $occur = [Occurence]::new($startPos, $endPos, $body, $raw)

    # Create function info
    $funcInfo = [FunctionInfo]::new($fullDeclaration, @($occur), $functionVariables, $attributes, $returnType)

    return $funcInfo
}

function Find-Functions {
    # returns a hashtable: key = declaration, value = FunctionInfo object (with variables parsed)
    param([string[]]$lines)
    
    $functions = @{}  # Dictionary: key = declaration, value = FunctionInfo object
    $i = 0
    
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        
        # Skip empty lines and comments
        if ($line.Trim() -eq "" -or $line.Trim().StartsWith("//") -or $line.Trim().StartsWith("/*")) {
            $i++
            continue
        }
        
        # Check for function declaration patterns
        if (Test-FunctionDeclaration -Line $line -Lines $lines -Index $i) {
            # Write-Verbose "Potential function found at line $($i + 1): $($line.Trim())"
            $functionInfo = Parse-Function -Lines $lines -StartIndex $i
            if ($functionInfo) {
                $declaration = $functionInfo.Declaration
                if ($functions.ContainsKey($declaration)) {
                    $functions[$declaration].Occurences += $functionInfo.Occurences
                }
                else {
                    $functions[$declaration] = $functionInfo
                }
                $i = $functionInfo.Occurences[0].End.Line - 1
                # Write-Verbose "Function parsed: $($functionInfo.Name)"
            }
            else {
                Write-Verbose "Failed to parse function at line $($i + 1)"
            }
        }
        
        $i++
    }
    
    return $functions
}

function Deduplicate-Functions {
    param(
        [hashtable]$Functions,  # $Functions: key = declaration, value = FunctionInfo object
        [string[]]$lines
    )
    Write-Host "Starting deduplication of functions..."
    $outputLines = @()
    $i = 0

    # Flatten all occurences into a list with their declaration
    $allOccurences = @()
    foreach ($declaration in $Functions.Keys) {
        $funcInfo = $Functions[$declaration]
        foreach ($occur in $funcInfo.Occurences) {
            $allOccurences += [PSCustomObject]@{
                Declaration = $declaration
                Occurence   = $occur
            }
        }
    }
    # Sort all occurrences by their start line to process in file order
    $allOccurences = $allOccurences | Sort-Object { $_.Occurence.Start.Line }
    Write-Host "Total function occurences to process: $($allOccurences.Count)"

    $dedupedCount = 0
    $skippedCount = 0

    # Track seen function signatures (name + args) in a hashset for fast lookup
    $seenMethods = @{}
    $skipLines = @{}
    # Mark all but the first occurrence of each signature for skipping
    foreach ($item in $allOccurences) {
        $occur = $item.Occurence
        $declaration = $item.Declaration
        if ($declaration -match '([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)') {
            $methodName = $Matches[1]
            $methodArgs = $Matches[2] -replace '\s+', ''
        }
        else {
            $methodName = $declaration
            $methodArgs = ""
        }
        $methodKey = "$methodName($methodArgs)"
        if (-not $seenMethods.ContainsKey($methodKey)) {
            $seenMethods[$methodKey] = $true
        }
        else {
            # Mark all lines of this duplicate function for skipping
            for ($j = $occur.Start.Line - 1; $j -lt $occur.End.Line; $j++) {
                $skipLines[$j] = $true
            }
            Write-Verbose "Skipping duplicate function: $methodKey (lines $($occur.Start.Line)-$($occur.End.Line))"
            $skippedCount++
        }
    }
    # Now, build the output, skipping marked lines
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $skipLines.ContainsKey($i)) {
            $outputLines += $lines[$i]
        }
    }
    $dedupedCount = $seenMethods.Count
    Write-Host "Deduplication complete. Unique functions added: $dedupedCount, duplicates skipped: $skippedCount"
    return $outputLines
}

function Print-Functions {
    param(
        [hashtable]$Functions
    )
    $duplicateCount = 0
    $functionNames = @{}
    Write-Host "Found functions: $($functions.Keys.Count)"
    foreach ($declaration in $functions.Keys) {
        $funcInfo = $functions[$declaration]
        $occurences = $funcInfo.Occurences
        # Try to extract method name from declaration
        if ($declaration -match '([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
            $methodName = $Matches[1]
        }
        else {
            $methodName = $declaration
        }
        $isNew = -not $functionNames.ContainsKey($methodName)
        $status = if ($isNew) { "new" } else { "duplicate" }
        if (-not $isNew) { $duplicateCount++ }
        $functionNames[$methodName] = $true
        $uniqueHashes = $occurences | ForEach-Object { $_.BodyHash } | Select-Object -Unique
        $isExtension = $funcInfo.Variables | Where-Object { $_.This } | Select-Object -First 1
        $extension = if ($isExtension) { "Extension " } else { "" }
        Write-Verbose "$($extension)Function: $($funcInfo.ReturnType) $($funcInfo.Name) (Occurences=$($occurences.Count) Hashes=$($uniqueHashes.Count) Variables=$($funcInfo.Variables.Count) Attributes=$($funcInfo.Attributes.Count))"
        Write-Verbose " Declaration: $declaration"
        if ($funcInfo.Variables.Count -gt 0) {
            Write-Verbose " Variables: $(($funcInfo.Variables | ForEach-Object { "[$($_.Type)] $($_.Name) = $($_.DefaultValue)" }) -join " | ")"
        }
        if ($funcInfo.Attributes.Count -gt 0) {
            Write-Verbose " Attributes: $(($funcInfo.Attributes | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", ")"
        }
        foreach ($occurence in $occurences) {
            $startOcc = $occurence.Start
            $endOcc = $occurence.End
            Write-Verbose "  Occurence: Start=($($startOcc.Line), $($startOcc.Column)) End=($($endOcc.Line), $($endOcc.Column)) BodyHash=$($occurence.BodyHash)"
        }
    }
    Write-Output "Total duplicates: $duplicateCount"
}

$content = Get-Content $InputFile
$functions = Find-Functions -Lines $content

Print-Functions -Functions $functions

if ($Fix) {
    $content = Deduplicate-Functions -Functions $functions -lines $content
    $content | Set-Content $OutputFile
    Write-Host "Deduplication complete. Output written to $OutputFile"
}

if ($Sort) {
    $functions = Find-Functions -Lines $content
    $firstFuncLine = $content.Count
    foreach ($declaration in $functions.Keys) {
        foreach ($occurence in $functions[$declaration].Occurences) {
            if ($occurence.Start.Line -lt $firstFuncLine) {
                $firstFuncLine = $occurence.Start.Line
            }
        }
    }
    Write-Host "First function line: $firstFuncLine"
    $lastFuncLine = 0
    foreach ($declaration in $functions.Keys) {
        foreach ($occurence in $functions[$declaration].Occurences) {
            if ($occurence.End.Line -gt $lastFuncLine) {
                $lastFuncLine = $occurence.End.Line
            }
        }
    }
    Write-Host "Last function line: $lastFuncLine"

    # Sort functions by first var type if first argument $Variable.This is true, otherwise by return type

    # Create a list of FunctionInfo objects
    $functionList = @()
    foreach ($declaration in $functions.Keys) {
        $functionList += $functions[$declaration]
    }

    # Sort the function list
    $sortedFunctions = $functionList | Sort-Object `
        @{ Expression = {
            if ($_.Variables.Count -gt 0 -and $_.Variables[0].This) {
                $_.Variables[0].Type
            } else {
                if ($_.ReturnType) { $_.ReturnType } else { "~" }
            }
        }}, `
        @{ Expression = { $_.Name } }

    # Gather all lines before the first function and after the last function
    $before = if ($firstFuncLine -gt 1) { $content[0..($firstFuncLine-2)] } else { @() }
    $after = if ($lastFuncLine -lt ($content.Count)) { $content[$lastFuncLine..($content.Count-1)] } else { @() }

    # Gather the function bodies in sorted order using $func.Raw
    $sortedFunctionLines = @()
    foreach ($func in $sortedFunctions) {
        $funcRawLines = $func.Occurences[0].Raw -split "`n"
        $sortedFunctionLines += $funcRawLines
        $sortedFunctionLines += "" # Add a blank line between functions
    }
    # Remove trailing blank line if present
    if ($sortedFunctionLines.Count -gt 0 -and $sortedFunctionLines[-1] -eq "") {
        $sortedFunctionLines = $sortedFunctionLines[0..($sortedFunctionLines.Count-2)]
    }

    # Compose the new content
    $newContent = @()
    if ($before.Count -gt 0) { $newContent += $before }
    if ($sortedFunctionLines.Count -gt 0) { $newContent += $sortedFunctionLines }
    if ($after.Count -gt 0) { $newContent += $after }

    $newContent | Set-Content $OutputFile
    Write-Host "Functions sorted and output written to $OutputFile"
}