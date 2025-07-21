param(
    [string]$NugetApiKey,
    [string]$Csproj,
    [string]$Version,
    [switch]$Nuget,
    [switch]$Github
)

function Bump-Version {
    param([string]$csproj)
    [xml]$projXml = Get-Content $csproj
    $versionNode = $projXml.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1
    if (-not $versionNode) {
        Write-Error "No <Version> property found in any <PropertyGroup> in $csproj"
        exit 1
    }
    $version = $versionNode.Version
    $parts = $version -split '\.'
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
    Write-Host "Bumped Version: $version -> $newVersion"
    return @{ Xml = $projXml; VersionNode = $versionNode; NewVersion = $newVersion; OldVersion = $version }
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

    # Bump version
    $bumpResult = Bump-Version -csproj $csproj
    if ($Version) {
        Set-Version -projXml $bumpResult.Xml -versionNode $bumpResult.VersionNode -newVersion $Version -csproj $csproj
        $newVersion = $Version
    } else {
        Set-Version -projXml $bumpResult.Xml -versionNode $bumpResult.VersionNode -newVersion $bumpResult.NewVersion -csproj $csproj
        $newVersion = $bumpResult.NewVersion
    }

    $oldVersion = $bumpResult.OldVersion

    # Build nupkg
    $projDir = Split-Path $csproj -Parent
    Push-Location $projDir

    dotnet clean
    # Check if the project is an executable
    [xml]$projXml = Get-Content $csproj
    $outputType = $projXml.Project.PropertyGroup | Where-Object { $_.OutputType } | Select-Object -First 1
    $isExe = $outputType.OutputType -eq 'Exe'

    if ($isExe) {
        $ret = dotnet publish -c Release --self-contained true /p:PublishSingleFile=true /p:IncludeAllContentForSelfExtract=true
    } else {
        $ret = dotnet publish -c Release
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error during dotnet publish $($LASTEXITCODE) $ret" -ForegroundColor Red
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
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($csproj)
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
        # dotnet build --configuration Release
    
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($csproj)
        $binPath = Get-ChildItem -Path 'bin/Release' -Include "$projectName.dll", "$projectName.exe" -Recurse | Select-Object -First 1
        if (-not $binPath) {
            Write-Error "No DLL or EXE found after build for $projectName."
            Pop-Location
            exit 1
        }

        # Create a new GitHub release for the new version and upload the DLL
        $tag = "v$newVersion"
        $releaseName = "Release $newVersion"
        $releaseNotes = "Automated release for version $newVersion."

        # Check if the release already exists
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $existingRelease = & gh release view $tag 2>$null
            $releaseExists = $true
        } catch {
            $releaseExists = $false
        }
        $ErrorActionPreference = 'Stop'
        if ($existingRelease -and $releaseExists) {
            Write-Host "Release $tag already exists. Uploading asset..."
            gh release upload $tag $binPath.FullName --clobber
        } else {
            Write-Host "Creating new release $tag and uploading asset..."
            gh release create $tag $binPath.FullName --title "$releaseName" --notes "$releaseNotes"
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
