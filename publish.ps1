param(
    [string]$NugetApiKey,
    [string]$Csproj,
    [string]$Version,
    [switch]$Nuget,
    [switch]$Github
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

    $outputFrameworkExe = $null;$outputStandaloneExe = $null
    if ($outputIsExe) {
        Write-Host "Building EXE..."
        # Framework-dependent build
        $ret1 = dotnet publish -c Release -r win-x64 --self-contained false
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during framework-dependent dotnet publish $($LASTEXITCODE) $ret1" -ForegroundColor Red
        }
        $outputFrameworkExe = Get-ChildItem -Path "bin/Release/net*/win-x64/publish/" -Include "$outputAssemblyName.exe" -Recurse | Select-Object -First 1
        if ($outputFrameworkExe) {
            Copy-Item $outputFrameworkExe.FullName (Join-Path $outputBinDir "$outputAssemblyName.framework.exe") -Force
        }

        # Self-contained build
        $ret2 = dotnet publish -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true /p:IncludeAllContentForSelfExtract=true
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during self-contained dotnet publish $($LASTEXITCODE) $ret2" -ForegroundColor Red
        }
        $outputStandaloneExe = Get-ChildItem -Path "bin/Release/net*/win-x64/publish/" -Include "$outputAssemblyName.exe" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($outputStandaloneExe) {
            Copy-Item $outputStandaloneExe.FullName (Join-Path $outputBinDir "$outputAssemblyName.standalone.exe") -Force
        }
    } else {
        Write-Host "Building DLL..."
        $ret = dotnet publish -c Release
        Copy-Item "bin/Release/net*/win-x64/publish/$outputAssemblyName.dll" (Join-Path $outputBinDir "$outputAssemblyName.dll") -Force
        Write-Host "DLL built successfully"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error during dotnet publish $($LASTEXITCODE) $ret" -ForegroundColor Red
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
        $outputBinPath = Get-ChildItem -Path $outputBinDir -Include "$outputAssemblyName.dll", "$outputAssemblyName.exe", "$outputAssemblyName.framework.exe", "$outputAssemblyName.standalone.exe" -Recurse | Select-Object -First 1
        $outputExeFramework = Join-Path $outputBinDir "$outputAssemblyName.framework.exe"
        $outputExeStandalone = Join-Path $outputBinDir "$outputAssemblyName.standalone.exe"
        $outputExeDefault = Join-Path $outputBinDir "$outputAssemblyName.exe"
        $assets = @()
        if ($outputBinPath) { $assets += $outputBinPath.FullName }
        if (Test-Path $outputExeDefault) { $assets += $outputExeDefault }
        if (Test-Path $outputExeFramework) { $assets += $outputExeFramework }
        if (Test-Path $outputExeStandalone) { $assets += $outputExeStandalone }
        if (-not $assets) {
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
        $assets = @()
        if ($outputBinPath) { $assets += $outputBinPath.FullName }
        if ($outputFrameworkExe) { $assets += $outputFrameworkExe.FullName }
        if ($outputStandaloneExe) { $assets += $outputStandaloneExe.FullName }
        if ($existingRelease -and $releaseExists) {
            Write-Host "Release $tag already exists. Uploading asset(s)..."
            foreach ($asset in $assets) {
                gh release upload $tag $asset --clobber
            }
        } else {
            Write-Host "Creating new release $tag and uploading asset(s)..."
            gh release create $tag $assets --title "$releaseName" --notes "$releaseNotes"
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
