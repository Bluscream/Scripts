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
    $projectDir = Split-Path $csproj -Parent
    Push-Location $projectDir
    [xml]$projectXml = Get-Content $csproj
    $projectAssemblyNameNode = $projectXml.Project.PropertyGroup | Where-Object { $_.AssemblyName } | Select-Object -First 1
    $projectVersionNode = $projectXml.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1
    $projectRIDNode = $projectXml.Project.PropertyGroup | Where-Object { $_.RuntimeIdentifier } | Select-Object -First 1
    $projectRIDsNode = $projectXml.Project.PropertyGroup | Where-Object { $_.RuntimeIdentifiers } | Select-Object -First 1
    $projectFrameworkNode = $projectXml.Project.PropertyGroup | Where-Object { $_.Framework } | Select-Object -First 1
    $projectTargetFrameworkNode = $projectXml.Project.PropertyGroup | Where-Object { $_.TargetFramework } | Select-Object -First 1
    $projectFramework = $projectTargetFrameworkNode.TargetFramework ?? $projectFrameworkNode.Framework;

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
    $outputIsExe = $outputType.OutputType -eq 'Exe'
    $outputBinDir = Join-Path $projectDir 'bin'
    $outputAssemblyName = $null
    if ($projectAssemblyNameNode -and $projectAssemblyNameNode.AssemblyName -and $projectAssemblyNameNode.AssemblyName -ne "") {
        $outputAssemblyName = $projectAssemblyNameNode.AssemblyName
    } else {
        $outputAssemblyName = $projectName
    }

    if (-not $projectVersionNode) {
        Write-Error "No <Version> property found in any <PropertyGroup> in $csproj"
        exit 1
    }
    $oldVersion = $projectVersionNode.Version
    if ($Version) {
        Set-Version -projXml $projectXml -versionNode $projectVersionNode -newVersion $Version -csproj $csproj
        $newVersion = $Version
    } else {
        $newVersion = Bump-Version -oldVersion $oldVersion
        Set-Version -projXml $projectXml -versionNode $projectVersionNode -newVersion $newVersion -csproj $csproj
    }

    dotnet clean
    if (-not (Test-Path $outputBinDir)) { New-Item -ItemType Directory -Path $outputBinDir | Out-Null } # outputBinDir gets removed by dotnet clean

    $outputFrameworkExe = $null;$outputStandaloneExe = $null;$outputBinPath = $null
    if ($outputIsExe) {
        Write-Host "Building EXE..."
        # Framework-dependent build
        dotnet publish -c Release -r $arch --self-contained false
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during framework-dependent dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
        }
        $outputFrameworkExe = Get-ChildItem -Path "bin/Release/" -Include "$outputAssemblyName.exe" -Recurse | Select-Object -First 1
        $fwExeName = "$outputAssemblyName$outputFrameworkSuffix"
        if ($outputFrameworkExe) {
            Copy-Item $outputFrameworkExe.FullName (Join-Path $outputBinDir $fwExeName) -Force
            Write-Host "Framework-dependent EXE built successfully: $fwExeName"
        }

        # Self-contained build
        dotnet publish -c Release -r $arch --self-contained true /p:PublishSingleFile=true /p:IncludeAllContentForSelfExtract=true
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during self-contained dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
        }
        $outputStandaloneExe = Get-ChildItem -Path "bin/Release/" -Include "$outputAssemblyName.exe" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
    } else {
        Write-Host "Building DLL..."
        dotnet publish -c Release -r $arch 
        $dllPath = Get-ChildItem -Path "bin/Release/" -Include "$outputAssemblyName.$outputBinarySuffix" -Recurse | Select-Object -First 1
        if ($dllPath) {
            Copy-Item $dllPath.FullName (Join-Path $outputBinDir "$outputAssemblyName.$outputBinarySuffix") -Force
            Write-Host "DLL built successfully: $outputAssemblyName$outputBinarySuffix.dll"
        } else {
            Write-Host "DLL not found after build" -ForegroundColor Red
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
        }
        # For upload, always use the arch-suffixed DLL name
        $outputBinPath = $null
        if (Test-Path (Join-Path $outputBinDir "$outputAssemblyName.$outputBinarySuffix")) {
            $outputBinPath = Join-Path $outputBinDir "$outputAssemblyName.$outputBinarySuffix"
        }
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
