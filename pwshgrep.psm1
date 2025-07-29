# https://raw.githubusercontent.com/JamesKehr/pwshgrep/refs/heads/main/pwshgrep.psm1

# fast find contents inside of files in a directory

using namespace System.Collections.Concurrent
using namespace System.Collections.Generic

<#

pwshgrep is a module that will [eventually] contain two tools: grep and ogrep.

GREP

grep is a dual mode search tool for PowerShell. It searches strings and text files for matches, and can accept pipeline input or run standalone.

    STRING MODE

    Acts grep-like by searching through a string. The string can be passed directly via the -String parameter or via the pipeline.

    pwshgrep cannot act perfectly like grep because PowerShell is object based and not text based. Some interpretation is needed by pwshgrep
    to determine what to search through.


    PATH (FILE) MODE

    Path mode causes the script to search for text inside of one or more file. Text files with the .txt extension is the default file type.

    The -Include parameter can be used to change the file extension, and file search options in general. This parameter is passed, as-is, to 
    Get-ChildItem, so the Include option(s) must follow the same rules.

    The -Recurse option will search through files in child directories of the root path.

OGREP (Object GREP)

Searches through PowerShell objects for string matches.




TO-DO:

V1 feature list:

- DONE - Run tests to find the optimal way to search the file system. Is Get-ChildItem the fastest?
   - Close, but using .NET is a tad quicker
- DONE - Run new tests to find out what the best way to search for text in files. Is it still "switch -regex -file"? StreamReader? Something else?
   - switch is fastest by a lot
- SCRATCH - Switch to path mode when a path string is passed.
   - REASON: The ParameterSetName is read-only and cannot be changed once the determination is made; however, this is a limited scenario with an easy workaround.
   - Using any param from the Path set name automatically switches pwshgrep to Path.

Example:

This command automatically uses the Path param set name -r (Recurse) is a Path-only option; likewise, adding include or file extension set parameters will have the same result of switching to Path mode.

'C:\data\' | grep "find me" -r

   - The only scenario where this is needed is when using the default *.txt file extension without recurse or other Path-only parameters.
   - Simply add Get-Item (alias: gi) in front of the string path to convert it to an object that triggers the Path param set.

Use:

Get-Item 'C:\data\' | grep "find me"

Instead of:

'C:\data\' | grep "find me"

- DONE - Add OpenFile() to [pwshgrepFileResult].
   - Simply run the file from the CLI and let Windows figure it which program to use based on defaults.
   - Use this method to compensate for spaces in the path: &"$($this.File)"
- DONE - Add type accelerators.

V2 features:
- Add stats to File search
  - Add stats to pwshgrepFileResult
  - Move the file search code to pwshgrepFileResult
  - Simply call the search from grep, let the class store and calculate performance results, per file.
  - Use Measure-Object to generate stats for the entire job.

- Grep features that should be added:
   - Case sensitive
   - Invert match
   - Count (no lines, just number of matches)
   - Quiet/silent


vFuture features:
ogrep...?
- Consider adding an object mode? It would effectively be a wrapper for Select-Object...?
    - The Pattern param in object mode searches the top level parameters for a string match.
    - A level parameter can be used to recurse to nested layers.
    - A level of -1 will recurse all levels.

#>

### CLASS ###
#region
class pwshgrepFileResult {
    [System.IO.FileSystemInfo]
    $File

    [int]
    $Line

    [string]
    $Result

    [string]
    $Root

    [string]
    $ShortPath

    hidden
    [regex]
    $Pattern

    pwshgrepFileResult([System.IO.FileSystemInfo]$f, [int]$l, [string]$r, [string]$rp, [regex]$p) {
        Write-Debug "[pwshgrepFileResult] - Begin"
        $this.File      = $f
        Write-Debug "[pwshgrepFileResult] - File: $($this.File)"
        $this.Line      = $l
        Write-Debug "[pwshgrepFileResult] - Line: $($this.Line)"
        $this.Result    = $r
        Write-Debug "[pwshgrepFileResult] - Result: $($this.Result)"
        $this.Root      = $rp
        Write-Debug "[pwshgrepFileResult] - Root: $($this.Root)"
        $this.GetShortPath()
        Write-Debug "[pwshgrepFileResult] - ShortPath: $($this.ShortPath)"
        $this.Pattern   = $p
        Write-Debug "[pwshgrepFileResult] - Pattern: $($this.Pattern)"
        Write-Debug "[pwshgrepFileResult] - End"
    }

    GetShortPath() {
        $tmp = $this.File.FullName
        $this.ShortPath = $tmp.Replace($this.Root, "..")
    }

    OpenFile() {
        &"$($this.File)"
    }

    [string]
    ToString() {
        return "$($this.File.Name) ($($this.Line)): $($this.Result)"
    }
}

$TypeData = @{
    TypeName   = 'pwshgrepFileResult'
    DefaultDisplayPropertySet = 'ShortPath', 'Line', 'Result'
}

Update-TypeData @TypeData -EA SilentlyContinue



class pwshgrepStringResult {
    [int]
    $Line

    [string]
    $Result

    hidden
    [regex]
    $Pattern

    pwshgrepStringResult([int]$l, [string]$r, [regex]$p) {
        Write-Debug "[pwshgrepStringResult] - Begin"
        $this.Line      = $l
        Write-Debug "[pwshgrepStringResult] - Line: $($this.Line)"
        $this.Result    = $r
        Write-Debug "[pwshgrepStringResult] - Result: $($this.Result)"
        $this.Pattern   = $p
        Write-Debug "[pwshgrepStringResult] - Pattern: $($this.Pattern)"
        Write-Debug "[pwshgrepStringResult] - End"
    }


    [string]
    ToString() {
        # statically set the formatted number length
        # supports up to 999 999 999 lines with a len of 9
        $len = 9
        return "$("{0:$len}" -f $this.Line): $($this.Result)"
    }
}

#endregion CLASS


function grep {
    #region PARAMETERS
    [CmdletBinding()]
    param (
        ## String parameters.
        # The text data to search through.
        [Parameter(
            Mandatory,
            ValueFromPipeline,
            ParameterSetName = "string"
        )]
        [Alias('s')]
        [string]
        $String,

        ## Path parameters.
        # The path, as a string or FileSystem object, to search through.
        [Parameter(
            Mandatory,
            ValueFromPipeline,
            ParameterSetName = "path"
        )]
        [Alias('f')]
        [System.IO.FileSystemInfo]
        [System.IO.DirectoryInfo]
        $Path,

        # Follows the same rules as -Include from Get-ChildItem, because this parameter is passed to Get-ChildItem -Include.
        [Parameter(
            Position = 1,
            ParameterSetName = "path"
        )]
        [string[]]
        $Include = $null,

        ## File extension groups go here ##
        # Searches through every file extension in the file extension groups/scenarios.
        [Parameter(ParameterSetName = "path")]
        [switch]
        [Alias("42", "AllGroups", "AllScenarios")]
        $All,

        # Searches through the following PowerShell files extensions: ps1, psm1, psd1
        [Parameter(ParameterSetName = "path")]
        [Alias('pwsh', 'PS')]
        [switch]
        $PowerShell,

        # Searches through common log file extensions: txt, log
        [Parameter(ParameterSetName = "path")]
        [switch]
        $Log,

        # Searches through common C++ file extensions: cpp, h, cc, cxx
        [Parameter(ParameterSetName = "path")]
        [switch]
        $Cpp,

        # Searches through common Python file extensions: py
        [Parameter(ParameterSetName = "path")]
        [switch]
        [Alias('py')]
        $Python,

        # Searches through common configuration file extensions: ini, conf, cfg, cnf, cf, json, xml, yaml, yml
        [Parameter(ParameterSetName = "path")]
        [switch]
        $Config,

        # Searches through files in child directories of the root path.
        [Parameter(ParameterSetName = "path")]
        [Alias('r')]
        [switch]
        $Recurse,

        ### Common parameters
        # A single regex pattern to use when searching through files. This is a case insensitive search.
        [Parameter(Position = 0)]
        [Alias('e')]
        [string]
        $Pattern
    )
    #endregion PARAMETERS

    begin {
        Write-Verbose "grep - Begin"
        Write-Verbose "grep - PSBoundParameters at Begin:`n$($PSBoundParameters | Format-List | Out-String)"

        ### common variables
        # valid data types, no arrays allowed (yet)
        $validObjType = [string], [System.IO.FileSystemInfo], [System.IO.DirectoryInfo]

        # the pattern must be a valid regex pattern
        try {
            Write-Verbose "grep - Test the pattern."
            $rPattern = [regex]::new($Pattern)
            Write-Verbose "grep - Pattern is regex compatible."
        } catch {
            throw "The Pattern is invalid. The search pattern must be .NET regex compatible. Error: $_"
        }

        ## update the search parameters based on scenario switches
        ## extensions can compound by adding multiple groups or using -All
        if ($PowerShell.IsPresent -or $All.IsPresent) {
            Write-Verbose "grep - Adding PowerShell file extensions."
            $Include += '*.ps1', '*.psm1', '*.psd1'
        }
        
        if ($Log.IsPresent -or $All.IsPresent) {
            Write-Verbose "grep - Adding log file extensions."
            $Include += '*.txt', '*.log'
        }
        
        if ($Cpp.IsPresent -or $All.IsPresent) {
            Write-Verbose "grep - Adding C++ file extensions."
            $Include += "*.cpp", "*.h", "*.cc", "*.cxx"
        }
        
        if ($Python.IsPresent -or $All.IsPresent) {
            Write-Verbose "grep - Adding Python file extensions."
            $Include += "*.py"
        }
        
        if ($Config.IsPresent -or $All.IsPresent) {
            Write-Verbose "grep - Adding configuration file extensions."
            $Include += "*.ini", "*.conf", "*.cfg", "*.cnf", "*.cf", "*.json", "*.xml", "*.yaml", "*.yml"
        }

        # make sure there is at least one include
        if ( $null -eq $Include) {
            Write-Verbose "grep - Using default file extension(s)."
            $Include = '*.txt'
        }

        Write-Verbose "grep - File extensions: $($Include -join ', ')"

        # track the line number as a zero-indexed value in String mode from multiple strings in the pipeline
        $strLine = 0

        # results are stored here for string results for pipelining purposes
        $strResults = [List[pwshgrepStringResult]]::new()

        # results are stored here for the Path mode
        $results = [List[pwshgrepFileResult]]::new()
    }


    process {
        Write-Verbose "grep - Process"
        Write-Debug "grep - PSBoundParameters at Process:`n$($PSBoundParameters | Format-List | Out-String)"

        switch ($PsCmdlet.ParameterSetName) {
            "path" {
                ### tests
                ## this can be anything, so make sure it's something understood by the script
                Write-Verbose "grep - Path: $($Path.ToString())"
                Write-Verbose "grep - Path data type: $($Path.GetType() | Format-List | Out-String)"
                $validType = $false
                :type foreach ($t in $validObjType) {
                    if ($Path -is $t) {
                        $validType = $true
                        break type
                    }
                }

                # throw an error if no valid types were found
                if ( -NOT $validType ) {
                    throw "This data type ($($Path.GetType())) is not valid for InputObject. The valid data types are: $($validObjType.FullName -join ', ' | Out-String)"
                }

                ## validate the path
                if ( -NOT (Test-Path "$Path" -IsValid -EA SilentlyContinue) ) {
                    throw "The path is not valid: $($Path.ToString())"
                }

                ## strings need to be converted to System.IO.FileSystemInfo, either way,
                ## create a FileSystem object as objPath to be used for the rest of the script
                if ($Path -is [string]) {
                    try {
                        $objPath = Get-Item $Path -EA Stop
                    } catch {
                        throw "Failed to convert the string path to a FileSystem object. Does the path exist? Error: $_"
                    }
                } else {
                    $objPath = $Path
                }


                Write-Verbose "grep - The unified path is: $($objPath.FullName)"
                Write-Verbose "grep - Object type: $($objPath.GetType().Name)"

                ### common tests ###
                # dir test
                if ( $objPath.PSIsContainer -or $objPath -is [System.IO.DirectoryInfo] ) {
                    Write-Verbose "grep - The path is a directory."
                    $isDir = $true
                }
                
                ### do work ###
                # get files if this is a directory
                if ($isDir) {
                    Write-Verbose "grep - Searching through the directory."

                    ## Get-ChildItem method
                    <#
                        Count             : 10
                        Average           : 1.90228132
                        Sum               : 19.0228132
                        Maximum           : 2.5201214
                        Minimum           : 1.5414072
                        StandardDeviation : 0.313651217152318
                        Property          :
                    #>

                    <# get matching files
                    try {
                        foreach ($i in $Include) {
                            if ($Recurse.IsPresent) {
                                [array]$files = Get-ChildItem $objPath -Include $Include -File -Recurse -EA Stop
                            } else {
                                [array]$files = Get-ChildItem $objPath -Include $Include -File -EA Stop
                            }
                        }
                    } catch {
                        throw "Failed to process files in $($objPath.FullName). Error: $_"
                    }
                    #>
                    
                    
                    ## EnumerateFiles method
                    <#
                        [List]
                        Count             : 10
                        Average           : 1.31686103
                        Sum               : 13.1686103
                        Maximum           : 1.5644336
                        Minimum           : 1.1280325
                        StandardDeviation : 0.145296228873965
                        Property          :
                    
                        [HashSet]
                        Count             : 10
                        Average           : 1.42974921
                        Sum               : 14.2974921
                        Maximum           : 1.8788529
                        Minimum           : 1.1879278
                        StandardDeviation : 0.18444281610667
                        Property          :

                    #>

                    $files = [List[Object]]::new() 
                    #$files = [HashSet[Object]]::new() 
                    $searchOptions = [System.IO.SearchOption]::AllDirectories
                    foreach ($inc in $Include) {
                        [System.IO.Directory]::EnumerateFiles(($objPath.FullName), $inc, $searchOptions) | & { process { $files.Add([System.IO.FileInfo]::new("$_")) }}
                    }
                    #>

                    #[array]$files = [System.IO.Directory]::EnumerateFiles("$($objPath.FullName)", $Include, $searchOptions) | & { process { Get-Item "$_" }}
                    #[array]$files = [System.IO.Directory]::EnumerateFiles("$($objPath.FullName)", $Include, $searchOptions) | & { process { [System.IO.FileInfo]::new("$_") }}
                    #[array]$files = [System.IO.Directory]::EnumerateFiles("$($objPath.FullName)", $Include, $searchOptions) | & { process { New-Object System.IO.FileInfo "$_" }}
                    #>

                # copy the file over for non-dirs
                } else {
                    Write-Verbose "grep - Using a single file search."
                    [array]$files = $objPath
                }

                if ($files.Count -eq 0) {
                    Write-Verbose "grep - No matching files found."
                    return $null
                } else {
                    Write-Verbose "$($files.Count) files found"
                }

                Write-Verbose "grep - The following files will be searched:`n$($files.FullName -join "`n")"
                Write-Verbose "grep - Pattern: $($rPattern.ToString())"

                # start the search
                # Does doing this in parallel help? Is there a good way to it that is cross-compat with pwsh 5.1 and 7.3+?
                # Thread jobs might work...
                foreach ($f in $files) {
                    # use zero-indexed lines to make scripting life easier
                    $line = 0
                    Write-Verbose "grep - Searching: $($f.Name)"

                    ## Switch method
                    switch -Regex -File $f {
                        $rPattern {
                            Write-Debug "grep - Found a match: $_"
                            # don't use a try as a performance optimization
                            $tmpRes = [pwshgrepFileResult]::new($f, $line, $_, $objPath.FullName, $rPattern)
                            $results.Add($tmpRes)

                            $tmpRes = $null
                            $line = $line + 1
                        }

                        default {$line = $line + 1}
                    }
                    #

                    <## StreamReader method
                    #
                    $streamReader = [System.IO.StreamReader] "$($f.FullName)"
                    try {
                        while ($streamReader.Peek() -ge 0) {
                            $strLine = $streamReader.ReadLine()
                            # Process each line
                            #Write-Host $line
                            #$tmpRes = [pwshgrepFileResult]::new($f, $line, $LogContent, $objPath.FullName, $rPattern)
                            $results.Add( ([pwshgrepFileResult]::new($f, $line, $strLine, $objPath.FullName, $rPattern)) )
                            # check for a match
                            if ($strLine -match $rPattern) {
                                # create the object and save it
                                Write-Debug "grep - [pwshgrepFileResult]::new($f, $line, $strLine, $($objPath.FullName), $rPattern)"
                                $tmpRes = [pwshgrepFileResult]::new($f, $line, $strLine, $objPath.FullName, $rPattern)
                                $results.Add($tmpRes)

                                $tmpRes = $null
                            }

                            $line = $line + 1
                        }
                    }
                    finally {
                        $streamReader.Close()
                    }
                    #>
                    

                    <#
                    $FileStream = New-Object -TypeName IO.FileStream -ArgumentList ($f.FullName), ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read)
                    $ReadLogFile = New-Object -TypeName System.IO.StreamReader -ArgumentList ($FileStream, [System.Text.Encoding]::ASCII, $true)
                    
                    # Read Lines
                    while (!$ReadLogFile.EndOfStream) {
                        # read the line
                        $LogContent = $ReadLogFile.ReadLine()

                        # check for a match
                        if ($LogContent -match $rPattern) {
                            # create the object and save it
                            Write-Debug "grep - [pwshgrepFileResult]::new($f, $line, $LogContent, $($objPath.FullName), $rPattern)"
                            $tmpRes = [pwshgrepFileResult]::new($f, $line, $LogContent, $objPath.FullName, $rPattern)
                            $results.Add($tmpRes)

                            $tmpRes = $null
                        }

                        $line = $line + 1
                    }
                    
                    $ReadLogFile.Close()
                    #>

                }
            }

            "string" {
                Write-Verbose "grep - String search."
                if ( -NOT [string]::IsNullOrEmpty($String) ) {
                    # split the string by new line (`n) and then search.
                    # older Windows new lines may contain a return (`r), so make that an optional parameter of the regex (`r?)
                    # [Environment]::NewLine doesn't appear to work...?
                    if ($string -match "\r?\n") {
                        Write-Debug "grep - split"
                        $line = 0
                        $string -Split "\r?\n" | & {process{
                            if ($_ -match $rPattern) {
                                Write-Debug "grep - String split matched."
                                $strResults.Add(( [pwshgrepStringResult]::new($line, $_, $rPattern) ))
                            }
    
                            # fast increment the line number
                            $line = $line + 1
                            Write-Verbose "grep - line: $line"
                        }}
                    # this path handles multiple strings from the pipeline when using, for example, Get-Content (alias: cat) or a [string[]] object
                    } else {
                        Write-Debug "grep - pipe: $String match $rPattern"
                        if ($String -match $rPattern) {
                            Write-Debug "grep - String matched."
                            $strResults.Add(( [pwshgrepStringResult]::new($strLine, $String, $rPattern) ))
                        }

                        # fast increment the line number
                        $strLine = $strLine + 1
                        Write-Verbose "grep - strLine: $strLine"
                    }
                } else {
                    Write-Verbose "grep - The string input is null or empty."
                }
            }
            
            default {
                throw "Unknown parameter set: $_"
            }
        }
    }

    end {
        Write-Verbose "grep - End"
        Write-Verbose "grep - Work Complete!"
        switch ($PsCmdlet.ParameterSetName) {
            "path"   {return $results}
            "string" {return $strResults}
        }
    }
}


#region TYPE ACCELERATORS
$ExportableTypes =@(
    [pwshgrepFileResult]
    [pwshgrepStringResult]
)

# Get the internal TypeAccelerators class to use its static methods.
$TypeAcceleratorsClass = [psobject].Assembly.GetType(
    'System.Management.Automation.TypeAccelerators'
)

# Ensure none of the types would clobber an existing type accelerator.
# If a type accelerator with the same name exists, throw an exception.
$ExistingTypeAccelerators = $TypeAcceleratorsClass::Get
foreach ($Type in $ExportableTypes) {
    if ($Type.FullName -in $ExistingTypeAccelerators.Keys) {
        # silently throw a message to the verbose stream
        Write-Verbose @"
Unable to register type accelerator[$($Type.FullName)]. The Accelerator already exists.
"@

    }
}

# Add type accelerators for every exportable type.
foreach ($Type in $ExportableTypes) {
    $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}

# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    foreach($Type in $ExportableTypes) {
        $TypeAcceleratorsClass::Remove($Type.FullName)
    }
}.GetNewClosure()

#endregion
