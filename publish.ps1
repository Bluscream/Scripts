param(
    [string]$NugetApiKey,
    [string]$Csproj,
    [string]$Version,
    [switch]$Nuget,
    [switch]$Github,
    [string]$Arch
)

function Bump-Version {
    param([string]$oldVersion)
    $parts = $oldVersion -split '\.'
    # Ensure at least 4 parts
    while ($parts.Count -lt 4) { $parts += '0' }
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]
    $build = [int]$parts[3]
    $build++
    if ($build -gt 9) {
        $build = 0
        $patch++
    }
    # If patch ever needs to roll over, add logic here
    $newVersion = "$major.$minor.$patch.$build"
    Write-Host "Bumped Version: $oldVersion -> $newVersion"
    return $newVersion
}
function Set-Version {
    param(
        [xml]$projXml,
        $versionNode,
        [string]$newVersion,
        [string]$csproj
    )
    $versionNode.Version = $newVersion
    $projXml.Save($csproj)
    Write-Host "Updated version to $newVersion in $csproj"
}

$ErrorActionPreference = 'Stop'

# Try to set NugetApiKey from environment if not provided
if (-not $NugetApiKey -or $NugetApiKey -eq "") {
    if ($env:NUGET_API_KEY) {
        $NugetApiKey = $env:NUGET_API_KEY
    }
}

if ($Nuget -and (-not $NugetApiKey -or $NugetApiKey -eq "")) {
    Write-Error "NugetApiKey is required for Nuget publishing. Please provide it as a parameter or set the NUGET_API_KEY environment variable."
    exit 1
}

# Find all .csproj files if not specified
if (-not $Csproj) {
    $csprojFiles = Get-ChildItem -Path (Get-Location) -Filter *.csproj -Recurse -ErrorAction SilentlyContinue
    if ($csprojFiles.Count -eq 0) {
        Write-Error "No .csproj files found."
        exit 1
    }
} else {
    $csprojFiles = @((Resolve-Path $Csproj).Path)
}

foreach ($csproj in $csprojFiles) {
    Write-Host "Processing $csproj..."

    # Project and output variables (define as early as possible)
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($csproj)
    Write-Host "Project name: $projectName"
    $projectDir = Split-Path $csproj -Parent
    Write-Host "Project directory: $projectDir"
    Push-Location $projectDir
    [xml]$projectXml = Get-Content $csproj
    $projectAssemblyNameNode = $projectXml.Project.PropertyGroup | Where-Object { $_.AssemblyName } | Select-Object -First 1
    $projectVersionNode = $projectXml.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1
    $projectRIDNode = $projectXml.Project.PropertyGroup | Where-Object { $_.RuntimeIdentifier } | Select-Object -First 1
    $projectRIDsNode = $projectXml.Project.PropertyGroup | Where-Object { $_.RuntimeIdentifiers } | Select-Object -First 1
    $projectFrameworkNode = $projectXml.Project.PropertyGroup | Where-Object { $_.Framework } | Select-Object -First 1
    $projectTargetFrameworkNode = $projectXml.Project.PropertyGroup | Where-Object { $_.TargetFramework } | Select-Object -First 1
    $projectFramework = $null
    if ($projectTargetFrameworkNode -and $projectTargetFrameworkNode.TargetFramework) {
        $projectFramework = $projectTargetFrameworkNode.TargetFramework
    } elseif ($projectFrameworkNode -and $projectFrameworkNode.Framework) {
        $projectFramework = $projectFrameworkNode.Framework
    }
    Write-Host "Project framework: $projectFramework"

    # Determine architecture
    if ($Arch) {
        $arch = $Arch
    } elseif ($projectRIDNode -and $projectRIDNode.RuntimeIdentifier) {
        $arch = $projectRIDNode.RuntimeIdentifier
    } elseif ($projectRIDsNode -and $projectRIDsNode.RuntimeIdentifiers) {
        $arch = ($projectRIDsNode.RuntimeIdentifiers -split ';')[0]
    } else {
        $arch = 'win-x64'
    }
    Write-Host "Using architecture: $arch"

    $outputFrameworkSuffix = ".$projectFramework.$arch.exe"
    $outputSelfcontainedSuffix = ".standalone.$arch.exe"
    $outputBinarySuffix = ".$arch"

    $outputType = $projectXml.Project.PropertyGroup | Where-Object { $_.OutputType } | Select-Object -First 1
    Write-Host "Output type: $outputType"
    $outputIsExe = $false
    if ($outputType.OutputType) {
        $outputTypeValue = $outputType.OutputType.ToString()
        $outputIsExe = ($outputTypeValue -ieq 'Exe' -or $outputTypeValue -ieq 'WinExe')
    }
    $outputBinDir = Join-Path $projectDir 'bin'
    Write-Host "Output binary directory: $outputBinDir"
    $outputAssemblyName = $null
    if ($projectAssemblyNameNode -and $projectAssemblyNameNode.AssemblyName -and $projectAssemblyNameNode.AssemblyName -ne "") {
        $outputAssemblyName = $projectAssemblyNameNode.AssemblyName
    } else {
        $outputAssemblyName = $projectName
    }
    Write-Host "Output assembly name: $outputAssemblyName"

    if (-not $projectVersionNode) {
        Write-Error "No <Version> property found in any <PropertyGroup> in $csproj"
        exit 1
    }
    $oldVersion = $projectVersionNode.Version
    Write-Host "Old version: $oldVersion"
    if ($Version) {
        Set-Version -projXml $projectXml -versionNode $projectVersionNode -newVersion $Version -csproj $csproj
        $newVersion = $Version
    } else {
        $newVersion = Bump-Version -oldVersion $oldVersion
        Set-Version -projXml $projectXml -versionNode $projectVersionNode -newVersion $newVersion -csproj $csproj
    }
    Write-Host "New version: $newVersion"

    function Kill-ProcessesByName {
        param (
            [string[]]$Names
        )
        foreach ($procName in $Names) {
            $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if ($procs) {
                Write-Host "Killing running process(es) named $procName..."
                foreach ($proc in $procs) {
                    try {
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        Write-Host "Killed process $($proc.Id) ($($proc.ProcessName))"
                    } catch {
                        Write-Host "Failed to kill process $($proc.Id): $_" -ForegroundColor Yellow
                    }
                }
            }
        }
    }
    $processNames = @($outputAssemblyName, "dotnet")
    Kill-ProcessesByName -Names $processNames

    dotnet clean
    # Delete bin and obj folders if they exist
    if (Test-Path $outputBinDir) { Remove-Item -Recurse -Force $outputBinDir }
    if (Test-Path "$projectDir/obj") { Remove-Item -Recurse -Force "$projectDir/obj" }
    if (-not (Test-Path $outputBinDir)) { New-Item -ItemType Directory -Path $outputBinDir | Out-Null } # outputBinDir gets removed by dotnet clean

    $outputFrameworkExe = $null;$outputStandaloneExe = $null;$outputBinPath = $null
    Write-Host "Building DLL..."
    dotnet publish -c Release -r $arch 
    $dllPath = Get-ChildItem -Path "bin/Release/" -Include "$outputAssemblyName.dll" -Recurse | Select-Object -First 1
    Write-Host "Output DLL: $dllPath"
    if ($dllPath) {
        $dllDest = Join-Path $outputBinDir "$outputAssemblyName$outputBinarySuffix.dll"
        Copy-Item $dllPath.FullName $dllDest -Force
        Write-Host "DLL built successfully: $dllDest"
    } else {
        Write-Host "DLL not found after build" -ForegroundColor Red
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error during dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
    }
    $outputBinPath = $null
    if (Test-Path (Join-Path $outputBinDir "$outputAssemblyName.$outputBinarySuffix")) {
        $outputBinPath = Join-Path $outputBinDir "$outputAssemblyName.$outputBinarySuffix"
    }
    Write-Host "Building Framework-dependent EXE..."
    # Framework-dependent build
    dotnet publish -c Release -r $arch --self-contained false
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error during framework-dependent dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
    }
    $outputFrameworkExe = Get-ChildItem -Path "bin/Release/" -Include "$outputAssemblyName.exe" -Recurse | Select-Object -First 1
    Write-Host "Output framework EXE: $outputFrameworkExe"
    $fwExeName = "$outputAssemblyName$outputFrameworkSuffix"
    if ($outputFrameworkExe) {
        Copy-Item $outputFrameworkExe.FullName (Join-Path $outputBinDir $fwExeName) -Force
        Write-Host "Framework-dependent EXE built successfully: $fwExeName"
    }
    Write-Host "Building Self-contained EXE..."
    dotnet publish -c Release -r $arch --self-contained true /p:PublishSingleFile=true /p:IncludeAllContentForSelfExtract=true
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error during self-contained dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
    }
    $outputStandaloneExe = Get-ChildItem -Path "bin/Release/" -Include "$outputAssemblyName.exe" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host "Output standalone EXE: $outputStandaloneExe"
    $scExeName = "$outputAssemblyName$outputSelfcontainedSuffix"
    if ($outputStandaloneExe) {
        Copy-Item $outputStandaloneExe.FullName (Join-Path $outputBinDir $scExeName) -Force
        Write-Host "Self-contained EXE built successfully: $scExeName"
    }
    # For upload, always use the arch-suffixed names
    if (Test-Path (Join-Path $outputBinDir $fwExeName)) {
        $outputBinPath = Join-Path $outputBinDir $fwExeName
    } elseif (Test-Path (Join-Path $outputBinDir $scExeName)) {
        $outputBinPath = Join-Path $outputBinDir $scExeName
    }

    # Check if .git exists, if not, initialize git repo
    if (-not (Test-Path ".git")) {
        Write-Host "Initializing new git repository..."
        git init

        # Create .gitignore if it does not exist
        if (-not (Test-Path ".gitignore")) {
            Write-Host "Creating .gitignore file..."
            @"
bin/
obj/
*.user
*.suo
*.userosscache
*.sln.docstates
.vs/
*.nupkg
*.snupkg
*.log
*.DS_Store
*.swp
*.scc
*.pdb
*.db
*.db-shm
*.db-wal
*.sqlite
*.sqlite3
*.bak
*.tmp
*.cache
*.TestResults/
TestResults/
"@ | Out-File -Encoding utf8 ".gitignore"
        }

        # Add all files and commit
        git add .
        git commit -m "Initial commit"

        # Create GitHub repo using gh cli
        Write-Host "Creating GitHub repository $projectName..."
        gh repo create $projectName --source . --public --confirm

        # Set remote origin if not set (gh repo create usually does this, but just in case)
        if (-not (git remote | Select-String "origin")) {
            $repoUrl = gh repo view $projectName --json url -q ".url"
            git remote add origin $repoUrl
        }

        # Push to GitHub
        git branch -M main
        git push -u origin main
    }

    if ($Github) {
        $assets = @(Get-ChildItem -Path $outputBinDir -Filter *.exe -File) + @(Get-ChildItem -Path $outputBinDir -Filter *.dll -File)
        if (-not $assets -or $assets.Count -eq 0) {
            Write-Error "No DLL or EXE found after build for $outputAssemblyName."
            Pop-Location
            exit 1
        }
        Write-Host "Assets: $assets"

        $tag = "v$newVersion"
        $releaseName = "Release $newVersion"
        $releaseNotes = "Automated release for version $newVersion."

        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $existingRelease = & gh release view $tag 2>$null
            $releaseExists = $true
        } catch {
            $releaseExists = $false
        }
        $ErrorActionPreference = 'Stop'
        if ($existingRelease -and $releaseExists) {
            Write-Host "Release $tag already exists. Uploading asset(s)..."
            foreach ($asset in $assets) {
                gh release upload $tag $($asset.FullName) --clobber
            }
        } else {
            Write-Host "Creating new release $tag and uploading asset(s)..."
            gh release create $tag ($assets | ForEach-Object { $_.FullName }) --title "$releaseName" --notes "$releaseNotes"
        }
    }

    if ($Nuget) {
        dotnet pack --configuration Release
    
        # Find nupkg
        $nupkg = Get-ChildItem -Path 'bin/Release' -Filter "$projectName.*.nupkg" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $nupkg) {
            Write-Error "No nupkg found for $projectName."
            Pop-Location
            exit 1
        }
        # Push to NuGet
        Write-Host "Pushing $($nupkg.FullName) to NuGet..."
        dotnet nuget push $nupkg.FullName --api-key $NugetApiKey --source https://api.nuget.org/v3/index.json --skip-duplicate

        # Open the NuGet package management page for the previous version in the default browser
        $packageUrl = "https://www.nuget.org/packages/$projectName/$oldVersion/Manage"
        Write-Host "Opening NuGet package management page for version $oldVersion..."
        Start-Process $packageUrl
    }

    Pop-Location
}
