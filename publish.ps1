# Publish script - handles publishing to various platforms
# Build functionality has been moved to build.ps1
# Git operations: commit in build.ps1, push in publish.ps1 (before publishing)
# Docker operations: build images in build.ps1, push to registries in publish.ps1
# Use -SkipBuild to skip the build step if you've already built the project
# Example: .\publish.ps1 -Nuget -Github -Docker -Ghcr -SkipBuild

param(
    [string]$Csproj,
    [string]$Version,
    [switch]$Nuget,
    [switch]$Github,
    [string]$Arch,
    [switch]$Git,
    [string]$Repo,
    [switch]$Release,
    [switch]$Debug,
    [switch]$Docker,
    [switch]$Ghcr,
    [switch]$SkipBuild
)

# Call build.ps1 if not skipping build
if (-not $SkipBuild) {
    Write-Host "Running build.ps1..."
    $buildParams = @()
    if ($Csproj) { $buildParams += "-Csproj"; $buildParams += $Csproj }
    if ($Version) { $buildParams += "-Version"; $buildParams += $Version }
    if ($Arch) { $buildParams += "-Arch"; $buildParams += $Arch }
    if ($Release) { $buildParams += "-Release" }
    if ($Debug) { $buildParams += "-Debug" }
    if ($Git) { $buildParams += "-Git" }
    if ($Docker -or $Ghcr) { $buildParams += "-Docker" }
    
    & "build.ps1" @buildParams
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'

# Try to set NugetApiKey from environment if not provided
$NugetApiKey = $env:NUGET_API_KEY

if ($Nuget -and (-not $NugetApiKey -or $NugetApiKey -eq "")) {
    Write-Error "NugetApiKey is required for Nuget publishing. Please set the NUGET_API_KEY environment variable."
    exit 1
}

# Find all .csproj files if not specified
if (-not $Csproj) {
    $csprojFiles = Get-ChildItem -Path (Get-Location) -Filter *.csproj -Recurse -ErrorAction SilentlyContinue
    if ($csprojFiles.Count -eq 0) {
        Write-Error "No .csproj files found."
        exit 1
    }
}
else {
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
    }
    elseif ($projectFrameworkNode -and $projectFrameworkNode.Framework) {
        $projectFramework = $projectFrameworkNode.Framework
    }
    Write-Host "Project framework: $projectFramework"

    # Determine architecture
    if ($Arch) {
        $arch = $Arch
    }
    elseif ($projectRIDNode -and $projectRIDNode.RuntimeIdentifier) {
        $arch = $projectRIDNode.RuntimeIdentifier
    }
    elseif ($projectRIDsNode -and $projectRIDsNode.RuntimeIdentifiers) {
        $arch = ($projectRIDsNode.RuntimeIdentifiers -split ';')[0]
    }
    else {
        $arch = 'win-x64'
    }
    Write-Host "Using architecture: $arch"

    $outputBinDir = Join-Path $projectDir 'bin'
    Write-Host "Output binary directory: $outputBinDir"
    $outputAssemblyName = $null
    if ($projectAssemblyNameNode -and $projectAssemblyNameNode.AssemblyName -and $projectAssemblyNameNode.AssemblyName -ne "") {
        $outputAssemblyName = $projectAssemblyNameNode.AssemblyName
    }
    else {
        $outputAssemblyName = $projectName
    }
    Write-Host "Output assembly name: $outputAssemblyName"

    # Get the current version for publishing
    $newVersion = $projectVersionNode.Version
    Write-Host "Current version for publishing: $newVersion"

    # Determine build configurations for Docker builds
    $buildConfigs = @()
    if ($Release) {
        $buildConfigs += "Release"
    }
    if ($Debug) {
        $buildConfigs += "Debug"
    }
    
    # Default to both Release and Debug if no configuration specified
    if ($buildConfigs.Count -eq 0) {
        $buildConfigs = @("Release", "Debug")
    }

    function Push-Git {
        Write-Host "Pushing changes to git..."
        git push
    }

    function Create-GitHubRepo {
        $repoName = if ($Repo) { $Repo } else { $projectName }
        Write-Host "Creating GitHub repository $repoName..."
        $repoUrl = git remote get-url origin
        if (-not $repoUrl) {
            gh repo create $repoName --source . --public --confirm
            $repoUrl = gh repo view $repoName --json url -q ".url"
            git remote add origin $repoUrl
            return $repoUrl
        }
        else {
            Write-Host "GitHub repository for $repoName already exists."
        }
    }

    function Publish-GitHubRelease {
        Write-Host "Publishing to GitHub Releases..."
        $assets = @(Get-ChildItem -Path $outputBinDir -Filter *.exe -File) + @(Get-ChildItem -Path $outputBinDir -Filter *.dll -File)
        if (-not $assets -or $assets.Count -eq 0) {
            Write-Error "No DLL or EXE found after build for $outputAssemblyName."
            return $false
        }
        Write-Host "Assets: $assets"

        $tag = "v$newVersion"
        $releaseName = "Release $newVersion"
        $releaseNotes = "Automated release for version $newVersion."

        $ErrorActionPreference = 'SilentlyContinue'
        $repoUrl = Create-GitHubRepo
        try {
            $existingRelease = & gh release view $tag 2>$null
            $releaseExists = $true
        }
        catch {
            $releaseExists = $false
        }
        $ErrorActionPreference = 'Stop'
        if ($existingRelease -and $releaseExists) {
            Write-Host "Release $tag already exists. Uploading asset(s)..."
            foreach ($asset in $assets) {
                gh release upload $tag $($asset.FullName) --clobber
            }
        }
        else {
            Write-Host "Creating new release $tag and uploading asset(s)..."
            gh release create $tag ($assets | ForEach-Object { $_.FullName }) --title "$releaseName" --notes "$releaseNotes"
        }
        return $true
    }

    function Publish-NuGet {
        Write-Host "Publishing to NuGet..."
        dotnet pack --configuration Release
    
        # Find nupkg
        $nupkg = Get-ChildItem -Path 'bin/Release' -Filter "$projectName.*.nupkg" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $nupkg) {
            Write-Error "No nupkg found for $projectName."
            return $false
        }
        # Push to NuGet
        Write-Host "Pushing $($nupkg.FullName) to NuGet..."
        dotnet nuget push $nupkg.FullName --api-key $NugetApiKey --source https://api.nuget.org/v3/index.json --skip-duplicate

        # Open the NuGet package management page for the current version in the default browser
        $packageUrl = "https://www.nuget.org/packages/$projectName/$newVersion/Manage"
        Write-Host "Opening NuGet package management page for version $newVersion..."
        Start-Process $packageUrl
        return $true
    }

    function Publish-DockerHub {
        Write-Host "Publishing to Docker Hub..."
        
        # Get username from environment variables
        $dockerUsername = if ($env:DOCKER_USERNAME) { $env:DOCKER_USERNAME } else { $env:USERNAME }
        
        if (-not $dockerUsername) {
            Write-Error "DOCKER_USERNAME environment variable is required for Docker publishing."
            return $false
        }
        
        $success = $true
        
        # Push for each configuration
        foreach ($config in $buildConfigs) {
            $configSuffix = if ($config -eq "Release") { ".release" } else { ".debug" }
            
            # Docker image names (built in build.ps1)
            $localImageName = "$projectName$configSuffix"
            $dockerImageName = "$dockerUsername/$projectName$configSuffix"
            $dockerTag = "${dockerImageName}:$newVersion"
            $dockerLatestTag = "${dockerImageName}:latest"
            
            # Tag local image with Docker Hub name
            Write-Host "Tagging local image for Docker Hub: $dockerTag"
            docker tag "${localImageName}:$newVersion" $dockerTag
            docker tag "${localImageName}:latest" $dockerLatestTag
            
            # Push to Docker Hub
            Write-Host "Pushing to Docker Hub: $dockerTag"
            docker push $dockerTag
            
            Write-Host "Pushing to Docker Hub: $dockerLatestTag"
            docker push $dockerLatestTag
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Successfully published to Docker Hub: $dockerImageName"
            }
            else {
                Write-Host "Failed to push to Docker Hub: $dockerImageName" -ForegroundColor Red
                $success = $false
            }
        }
        return $success
    }

    function Publish-GHCR {
        Write-Host "Publishing to GitHub Container Registry..."
        
        # Get username from environment variables
        $githubUsername = if ($env:GITHUB_USERNAME) { $env:GITHUB_USERNAME } else { $env:USERNAME }
        
        if (-not $githubUsername) {
            Write-Error "GITHUB_USERNAME environment variable is required for GHCR publishing."
            return $false
        }
        
        $success = $true
        
        # Push for each configuration
        foreach ($config in $buildConfigs) {
            $configSuffix = if ($config -eq "Release") { ".release" } else { ".debug" }
            
            # Docker image names (built in build.ps1)
            $localImageName = "$projectName$configSuffix"
            $ghcrImageName = "ghcr.io/$githubUsername/$projectName$configSuffix"
            $ghcrTag = "${ghcrImageName}:$newVersion"
            $ghcrLatestTag = "${ghcrImageName}:latest"
            
            # Tag local image with GHCR name
            Write-Host "Tagging local image for GHCR: $ghcrTag"
            docker tag "${localImageName}:$newVersion" $ghcrTag
            docker tag "${localImageName}:latest" $ghcrLatestTag
            
            # Push to GHCR
            Write-Host "Pushing to GHCR: $ghcrTag"
            docker push $ghcrTag
            
            Write-Host "Pushing to GHCR: $ghcrLatestTag"
            docker push $ghcrLatestTag
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Successfully published to GHCR: $ghcrImageName"
            }
            else {
                Write-Host "Failed to push to GHCR: $ghcrImageName" -ForegroundColor Red
                $success = $false
            }
        }
        return $success
    }




    # Push to git first if requested
    if ($Git) {
        Write-Host "Pushing to git before publishing..."
        Push-Git
    }

    # Track publishing success
    $publishSuccess = $true

    if ($Github) {
        if (-not (Publish-GitHubRelease)) {
            $publishSuccess = $false
        }
    }

    if ($Nuget) {
        if (-not (Publish-NuGet)) {
            $publishSuccess = $false
        }
    }

    if ($Docker) {
        if (-not (Publish-DockerHub)) {
            $publishSuccess = $false
        }
    }

    if ($Ghcr) {
        if (-not (Publish-GHCR)) {
            $publishSuccess = $false
        }
    }

    # Summary
    if ($publishSuccess) {
        Write-Host "All publishing operations completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Warning "Some publishing operations failed. Check the output above for details."
    }

    Pop-Location
}
