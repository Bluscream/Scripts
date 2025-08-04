# Consolidated build and publish script
# Combines all functionality from Publish-Module.psm1 with a -Publish flag

param(
    [string]$Version = "",
    [string]$Arch = "win-x64",
    [switch]$Release,
    [switch]$Debug,
    [switch]$Git,
    [switch]$Docker,
    [switch]$Publish,
    [switch]$Github,
    [switch]$Ghcr,
    [switch]$Nuget,
    [string]$Repo
)

# Gitignore template
$gitignore_template = @"
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
*.exe
*.dll
*.pdb
*.xml
*.json
*.config
*.log
*.env
"@

function Get-Username {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("github", "docker")]
        [string]$Service
    )

    $service = $Service.ToLower()
    $username = $null

    switch ($service) {
        "github" {
            # 1. Prefer explicit environment variable
            if ($env:GITHUB_USERNAME) {
                Write-Host "Using GITHUB_USERNAME environment variable: $env:GITHUB_USERNAME"
                $username = $env:GITHUB_USERNAME
                break
            }

            # 2. Try to extract from git remote
            if (Test-Path ".git") {
                try {
                    $remotes = git remote -v 2>$null
                    foreach ($remote in $remotes) {
                        if ($remote -match "github\.com[:/]([^/]+)/") {
                            $username = $matches[1]
                            Write-Host "Extracted GitHub username '$username' from git remote"
                            break
                        }
                    }
                } catch {
                    Write-Warning "Failed to read git remotes: $_"
                }
                if ($username) { break }
            }

            # 3. Fallback to system username
            if ($env:USERNAME) {
                Write-Host "Falling back to system USERNAME: $env:USERNAME"
                $username = $env:USERNAME
                break
            }

            Write-Error "Could not determine GitHub username. Set GITHUB_USERNAME environment variable or ensure a valid git remote exists."
            return $null
        }
        "docker" {
            # 1. Prefer explicit environment variable
            if ($env:DOCKER_USERNAME) {
                Write-Host "Using DOCKER_USERNAME environment variable: $env:DOCKER_USERNAME"
                $username = $env:DOCKER_USERNAME
                break
            }

            # 2. Fallback to system username
            if ($env:USERNAME) {
                Write-Host "Falling back to system USERNAME: $env:USERNAME"
                $username = $env:USERNAME
                break
            }

            Write-Error "Could not determine Docker username. Set DOCKER_USERNAME environment variable or ensure USERNAME is set."
            return $null
        }
    }

    if ($username) {
        return $username.ToLower()
    } else {
        Write-Error "Could not determine username for service '$Service'."
        return $null
    }
}

function Bump-Version {
    param([string]$oldVersion)
    $parts = $oldVersion -split '\.'
    # Ensure at least 4 parts
    if (-not $oldVersion -or ($oldVersion -notmatch '^\d+(\.\d+){0,3}$')) {
        $oldVersion = "1.0.0.0"
    }
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
                }
                catch {
                    Write-Host "Failed to kill process $($proc.Id): $_" -ForegroundColor Yellow
                }
            }
        }
    }
}

function Commit-Git {
    Write-Host "Committing changes to git..."

    if (-not (Test-Path ".git")) {
        Write-Host "Initializing new git repository..."
        git init        
        git branch -M main
    }

    if (-not (Test-Path ".gitignore")) {
        Write-Host "Creating .gitignore file..."
        $gitignore_template | Out-File -Encoding utf8 ".gitignore"
    }
    git add .
    $datetime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    git commit -m "Build at $datetime"
}

function Push-Git {
    Write-Host "Pushing changes to git..."
    git push
}

function Build-DockerImages {
    param(
        [string]$projectDir,
        [string]$projectName,
        [string]$newVersion,
        [string[]]$buildConfigs,
        [string]$repo
    )
    
    Write-Host "Building Docker images..."
    
    # Find Dockerfile(s)
    $dockerfiles = Get-ChildItem -Path $projectDir -Filter "Dockerfile*" -Recurse -ErrorAction SilentlyContinue
    if ($dockerfiles.Count -eq 0) {
        Write-Host "No Dockerfile found in $projectDir. Creating a default Dockerfile..."
        $dockerfileContent = @"
FROM mcr.microsoft.com/dotnet/runtime:8.0 AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["$projectName.csproj", "./"]
RUN dotnet restore "$projectName.csproj"
COPY . .
WORKDIR "/src"
RUN dotnet build "$projectName.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "$projectName.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "$projectName.dll"]
"@
        $dockerfilePath = Join-Path $projectDir "Dockerfile"
        $dockerfileContent | Out-File -FilePath $dockerfilePath -Encoding UTF8
        $dockerfiles = @(Get-Item $dockerfilePath)
        Write-Host "Created default Dockerfile at $dockerfilePath"
    }
    
         foreach ($dockerfile in $dockerfiles) {
         Write-Host "Processing Dockerfile: $($dockerfile.FullName)"
         
         # Determine configuration based on Dockerfile name
         $dockerfileName = $dockerfile.Name
         $configToBuild = $null
         
         if ($dockerfileName -eq "Dockerfile") {
             # Default Dockerfile builds release
             $configToBuild = "Release"
         }
         elseif ($dockerfileName -eq "Dockerfile.debug") {
             # Dockerfile.debug builds debug
             $configToBuild = "Debug"
         }
         elseif ($dockerfileName -match "^Dockerfile\.(.+)$") {
             # Dockerfile.(something) builds the (something) configuration
             $configToBuild = $matches[1]
         }
         
         # Only build if this configuration is requested
         if ($configToBuild -and $buildConfigs -contains $configToBuild) {
             $configTag = if ($configToBuild -eq "Release") { "release" } else { "debug" }
             
             # Build Docker image using repository name as base
             $dockerImageName = if ($repo) { $repo.ToLower() } else { $projectName.ToLower() }
             $dockerTag = "${dockerImageName}:$configTag-$newVersion"
             $dockerLatestTag = "${dockerImageName}:$configTag-latest"
             
             Write-Host "Building Docker image: $dockerTag"
             docker build -f $dockerfile.FullName -t $dockerTag --build-arg CONFIGURATION=$configToBuild .
             
             if ($LASTEXITCODE -eq 0) {
                 Write-Host "Docker image built successfully: $dockerTag" -ForegroundColor Green
                 
                 # Tag as latest
                 docker tag $dockerTag $dockerLatestTag
                 Write-Host "Tagged as latest: $dockerLatestTag" -ForegroundColor Green
             }
             else {
                 Write-Host "Failed to build Docker image: $dockerTag" -ForegroundColor Red
             }
         }
         else {
             Write-Host "Skipping Dockerfile $dockerfileName - configuration '$configToBuild' not in requested build configs: $($buildConfigs -join ', ')" -ForegroundColor Yellow
         }
     }
}

function Publish-GitHubRelease {
    param(
        [string]$projectName,
        [string]$newVersion,
        [string]$outputBinDir,
        [string]$repo
    )
    
    Write-Host "Publishing to GitHub Releases..."
    
    # Check if gh CLI is available
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "GitHub CLI (gh) is not installed or not in PATH."
        return $false
    }
    
    # Get GitHub username
    $githubUsername = Get-Username -Service "gitHub"
    if (-not $githubUsername) {
        return $false
    }
    
    # Construct full repo name if only repo name is provided
    $fullRepoName = if ($repo -like "*/*") { $repo } else { "$githubUsername/$repo" }
    
    # Create release
    $releaseTitle = "Release $newVersion"
    $releaseBody = "Automated release for version $newVersion"
    
    Write-Host "Creating GitHub release: $releaseTitle"
    gh release create $newVersion --title $releaseTitle --notes $releaseBody --repo $fullRepoName
    
         if ($LASTEXITCODE -ne 0) {
         Write-Host "Failed to create GitHub release" -ForegroundColor Red
         return $false
     }
     else {
         Write-Host "GitHub release created successfully" -ForegroundColor Green
     }
     
    # Upload assets in parallel - only get files from the main bin directory, not subdirectories
    $assets = Get-ChildItem -Path $outputBinDir -Include *.exe,*.dll,*.nupkg -File
    $uploadJobs = @()
    
    foreach ($asset in $assets) {
        Write-Host "Starting upload for asset: $($asset.Name)"
        $job = Start-Job -ScriptBlock {
            param($assetPath, $version, $repo)
            try {
                $output = gh release upload $version $assetPath --repo $repo 2>&1
                $exitCode = $LASTEXITCODE
                return @{
                    Name = [System.IO.Path]::GetFileName($assetPath)
                    ExitCode = $exitCode
                    Output = $output
                }
            }
            catch {
                return @{
                    Name = [System.IO.Path]::GetFileName($assetPath)
                    ExitCode = 1
                    Output = $_.Exception.Message
                }
            }
        } -ArgumentList $asset.FullName, $newVersion, $fullRepoName
        $uploadJobs += $job
    }
    
    # Wait for all uploads to complete and collect results
    Write-Host "Waiting for all asset uploads to complete..."
    $results = $uploadJobs | Wait-Job | Receive-Job
    
         # Report results
     foreach ($result in $results) {
         if ($result.ExitCode -eq 0) {
             Write-Host "Successfully uploaded: $($result.Name)" -ForegroundColor Green
         }
         else {
             Write-Host "Failed to upload: $($result.Name)" -ForegroundColor Red
             if ($result.Output) {
                 Write-Host "  Error: $($result.Output)" -ForegroundColor Red
             }
         }
     }
    
    # Clean up jobs
    $uploadJobs | Remove-Job
    
    return $true
}

function Publish-NuGet {
    param(
        [string]$projectName,
        [string]$newVersion,
        [string]$outputBinDir
    )
    
    Write-Host "Publishing to NuGet..."
    
    $NugetApiKey = $env:NUGET_API_KEY
    if (-not $NugetApiKey) {
        Write-Error "NUGET_API_KEY environment variable is required for NuGet publishing."
        return $false
    }
    
    # Find .nupkg files
    $nupkgFiles = Get-ChildItem -Path $outputBinDir -Filter "*.nupkg" -Recurse
    if ($nupkgFiles.Count -eq 0) {
        Write-Host "No .nupkg files found to publish"
        return $false
    }
    
    $success = $true
    foreach ($nupkg in $nupkgFiles) {
        Write-Host "Publishing NuGet package: $($nupkg.Name)"
        dotnet nuget push $nupkg.FullName --api-key $NugetApiKey --source https://api.nuget.org/v3/index.json
        
                 if ($LASTEXITCODE -eq 0) {
             Write-Host "Successfully published: $($nupkg.Name)" -ForegroundColor Green
         }
         else {
             Write-Host "Failed to publish: $($nupkg.Name)" -ForegroundColor Red
             $success = $false
         }
    }
    
    return $success
}

function Publish-DockerHub {
    param(
        [string]$projectName,
        [string]$newVersion,
        [string[]]$buildConfigs,
        [string]$repo
    )
    
    Write-Host "Publishing to Docker Hub..."
    
    # Get Docker username
    $dockerUsername = Get-Username -Service "docker"
    if (-not $dockerUsername) {
        return $false
    }
    
    $success = $true
    foreach ($config in $buildConfigs) {
        $configTag = if ($config -eq "Release") { "release" } else { "debug" }
        $localImageName = "$($projectName.ToLower())"
        # Use repo name if provided, otherwise fall back to project name
        $imageBaseName = if ($repo) { $repo } else { $projectName.ToLower() }
        $dockerImageName = "$dockerUsername/$imageBaseName"
        $dockerTag = "${dockerImageName}:$configTag-$newVersion"
        $dockerLatestTag = "${dockerImageName}:$configTag-latest"
        
        Write-Host "Tagging local image for Docker Hub: $dockerTag"
        docker tag "${localImageName}:$configTag-$newVersion" $dockerTag
        docker tag "${localImageName}:$configTag-latest" $dockerLatestTag
        
        Write-Host "Pushing to Docker Hub: $dockerTag"
        docker push $dockerTag
        Write-Host "Pushing to Docker Hub: $dockerLatestTag"
        docker push $dockerLatestTag
        
                 if ($LASTEXITCODE -eq 0) {
             Write-Host "Successfully published to Docker Hub: $dockerImageName" -ForegroundColor Green
         }
         else {
             Write-Host "Failed to push to Docker Hub: $dockerImageName" -ForegroundColor Red
             $success = $false
         }
    }
    
    return $success
}

function Publish-GHCR {
    param(
        [string]$projectName,
        [string]$newVersion,
        [string[]]$buildConfigs,
        [string]$repo
    )
    
    Write-Host "Publishing to GitHub Container Registry (GHCR)..."
    
    # Get GitHub username
    $githubUsername = Get-Username -Service "GitHub"
    if (-not $githubUsername) {
        return $false
    }
    # Ensure lowercase for Docker compliance
    $githubUsername = $githubUsername.ToLower()
    
    $success = $true
    foreach ($config in $buildConfigs) {
        $configTag = if ($config -eq "Release") { "release" } else { "debug" }
        $localImageName = "$($projectName.ToLower())"
        # Use repo name if provided, otherwise fall back to project name
        $imageBaseName = if ($repo) { $repo } else { $projectName.ToLower() }
        $ghcrImageName = "ghcr.io/$githubUsername/$imageBaseName"
        $ghcrTag = "${ghcrImageName}:$configTag-$newVersion"
        $ghcrLatestTag = "${ghcrImageName}:$configTag-latest"
        
        Write-Host "Tagging local image for GHCR: $ghcrTag"
        docker tag "${localImageName}:$configTag-$newVersion" $ghcrTag
        docker tag "${localImageName}:$configTag-latest" $ghcrLatestTag
        
        Write-Host "Pushing to GHCR: $ghcrTag"
        docker push $ghcrTag
        Write-Host "Pushing to GHCR: $ghcrLatestTag"
        docker push $ghcrLatestTag
        
                 if ($LASTEXITCODE -eq 0) {
             Write-Host "Successfully published to GHCR: $ghcrImageName" -ForegroundColor Green
         }
         else {
             Write-Host "Failed to push to GHCR: $ghcrImageName" -ForegroundColor Red
             $success = $false
         }
    }
    
    return $success
}

function Build-Project {
    param(
        [string]$Version = "",
        [string]$Arch = "win-x64",
        [switch]$Release,
        [switch]$Debug,
        [switch]$Git,
        [switch]$Docker
    )
    
    $ErrorActionPreference = 'Stop'
    
    # Find all .csproj files or .sln files
    Write-Host "Searching for project files..."
    $slnFiles = Get-ChildItem -Path (Get-Location) -Filter *.sln -Recurse -ErrorAction SilentlyContinue
    $csprojFiles = Get-ChildItem -Path (Get-Location) -Filter *.csproj -Recurse -ErrorAction SilentlyContinue

    if ($slnFiles.Count -gt 0) {
        Write-Host "Found .sln file(s): $($slnFiles.Name -join ', ')"
        Write-Host "Using solution file: $($slnFiles[0].FullName)"
        # For now, we'll use the first .sln file and build all projects in it
        # In the future, we could parse the .sln file to get specific projects
        $csprojFiles = Get-ChildItem -Path (Get-Location) -Filter *.csproj -Recurse -ErrorAction SilentlyContinue
    }
    elseif ($csprojFiles.Count -gt 0) {
        Write-Host "Found .csproj file(s): $($csprojFiles.Name -join ', ')"
    }
    else {
        Write-Error "No .csproj or .sln files found."
        return $false
    }

    foreach ($csproj in $csprojFiles) {
        Write-Host "Processing $($csproj.FullName)..."

        # Project and output variables (define as early as possible)
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($csproj.Name)
        Write-Host "Project name: $projectName"
        $projectDir = $csproj.DirectoryName
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

        # Determine build configurations
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
        
        Write-Host "Build configurations: $($buildConfigs -join ', ')"

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
        }
        else {
            $outputAssemblyName = $projectName
        }
        Write-Host "Output assembly name: $outputAssemblyName"

        if (-not $projectVersionNode) {
            Write-Host "No <Version> property found in any <PropertyGroup> in $csproj. Creating one with default version 1.0.0.0."
            $firstPropertyGroup = $projectXml.Project.PropertyGroup | Select-Object -First 1
            if (-not $firstPropertyGroup) {
                Write-Error "No <PropertyGroup> found in $csproj to add <Version> property."
                return $false
            }
            $newVersion = '1.0.0.0'
            $versionElement = $projectXml.CreateElement('Version')
            $versionElement.InnerText = $newVersion
            $firstPropertyGroup.AppendChild($versionElement) | Out-Null
            $projectXml.Save($csproj)
            Write-Host "Created <Version> property with value $newVersion in $csproj."
        }
        else {
            $oldVersion = $projectVersionNode.Version
            Write-Host "Old version: $oldVersion"
            if ($Version) {
                Set-Version -projXml $projectXml -versionNode $projectVersionNode -newVersion $Version -csproj $csproj
                $newVersion = $Version
            }
            else {
                $newVersion = Bump-Version -oldVersion $oldVersion
                Set-Version -projXml $projectXml -versionNode $projectVersionNode -newVersion $newVersion -csproj $csproj
            }
            Write-Host "New version: $newVersion"
        }

        $processNames = @($outputAssemblyName, "dotnet")
        Kill-ProcessesByName -Names $processNames

        dotnet clean
        # Delete bin and obj folders if they exist
        if (Test-Path $outputBinDir) { Remove-Item -Recurse -Force $outputBinDir }
        if (Test-Path "$projectDir/obj") { Remove-Item -Recurse -Force "$projectDir/obj" }
        if (-not (Test-Path $outputBinDir)) { New-Item -ItemType Directory -Path $outputBinDir | Out-Null } # outputBinDir gets removed by dotnet clean

        $outputFrameworkExe = $null; $outputStandaloneExe = $null; $outputBinPath = $null
        
        # Build for each configuration
        foreach ($config in $buildConfigs) {
            Write-Host "Building for configuration: $config"
            
            # Determine suffix based on configuration
            $configSuffix = if ($config -eq "Release") { ".release" } else { ".debug" }
            $outputFrameworkSuffixWithConfig = ".$projectFramework.$arch$configSuffix.exe"
            $outputSelfcontainedSuffixWithConfig = ".standalone.$arch$configSuffix.exe"
            $outputBinarySuffixWithConfig = ".$arch$configSuffix"
            
            Write-Host "Building DLL for $config..."
            dotnet publish -c $config -r $arch 
            $dllPath = Get-ChildItem -Path "bin/$config/" -Include "$outputAssemblyName.dll" -Recurse | Select-Object -First 1
            Write-Host "Output DLL: $dllPath"
                         if ($dllPath) {
                 $dllDest = Join-Path $outputBinDir "$outputAssemblyName$outputBinarySuffixWithConfig.dll"
                 Copy-Item $dllPath.FullName $dllDest -Force
                 Write-Host "DLL built successfully: $dllDest" -ForegroundColor Green
             }
             else {
                 Write-Host "DLL not found after build" -ForegroundColor Red
             }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error during dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
            }
            
            Write-Host "Building Framework-dependent EXE for $config..."
            # Framework-dependent build
            dotnet publish -c $config -r $arch --self-contained false
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error during framework-dependent dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
            }
            $outputFrameworkExe = Get-ChildItem -Path "bin/$config/" -Include "$outputAssemblyName.exe" -Recurse | Select-Object -First 1
            Write-Host "Output framework EXE: $outputFrameworkExe"
            $fwExeName = "$outputAssemblyName$outputFrameworkSuffixWithConfig"
                         if ($outputFrameworkExe) {
                 Copy-Item $outputFrameworkExe.FullName (Join-Path $outputBinDir $fwExeName) -Force
                 Write-Host "Framework-dependent EXE built successfully: $fwExeName" -ForegroundColor Green
             }
            
            Write-Host "Building Self-contained EXE for $config..."
            dotnet publish -c $config -r $arch --self-contained true /p:PublishSingleFile=true /p:IncludeAllContentForSelfExtract=true
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error during self-contained dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
            }
            $outputStandaloneExe = Get-ChildItem -Path "bin/$config/" -Include "$outputAssemblyName.exe" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            Write-Host "Output standalone EXE: $outputStandaloneExe"
            $scExeName = "$outputAssemblyName$outputSelfcontainedSuffixWithConfig"
                         if ($outputStandaloneExe) {
                 Copy-Item $outputStandaloneExe.FullName (Join-Path $outputBinDir $scExeName) -Force
                 Write-Host "Self-contained EXE built successfully: $scExeName" -ForegroundColor Green
             }
            
            # For upload, always use the arch-suffixed names
            if (Test-Path (Join-Path $outputBinDir $fwExeName)) {
                $outputBinPath = Join-Path $outputBinDir $fwExeName
            }
            elseif (Test-Path (Join-Path $outputBinDir $scExeName)) {
                $outputBinPath = Join-Path $outputBinDir $scExeName
            }
        }

        if ($Git) {
            Commit-Git
        }

        # Build Docker images if requested
        if ($Docker) {
            Build-DockerImages -projectDir $projectDir -projectName $projectName -newVersion $newVersion -buildConfigs $buildConfigs -repo $Repo
        }

        Pop-Location
    }
    
    return $true
}

function Publish-Project {
    param(
        [string]$Version = "",
        [string]$Arch = "win-x64",
        [switch]$Nuget,
        [switch]$Github,
        [switch]$Git,
        [string]$Repo,
        [switch]$Release,
        [switch]$Debug,
        [switch]$Docker,
        [switch]$Ghcr
    
    )
    
    $ErrorActionPreference = 'Stop'
    
    # Get project info for publishing
    $csprojFiles = Get-ChildItem -Path (Get-Location) -Filter *.csproj -Recurse -ErrorAction SilentlyContinue
    if ($csprojFiles.Count -eq 0) {
        Write-Error "No .csproj files found for publishing."
        return $false
    }
    
    $csproj = $csprojFiles[0] # Use first project for publishing
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($csproj.Name)
    $projectDir = $csproj.DirectoryName
    $outputBinDir = Join-Path $projectDir 'bin'
    
    # Get current version
    [xml]$projectXml = Get-Content $csproj
    $projectVersionNode = $projectXml.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1
    $newVersion = if ($projectVersionNode) { $projectVersionNode.Version } else { "1.0.0.0" }
    
    # Determine build configurations
    $buildConfigs = @()
    if ($Release) { $buildConfigs += "Release" }
    if ($Debug) { $buildConfigs += "Debug" }
    if ($buildConfigs.Count -eq 0) { $buildConfigs = @("Release", "Debug") }
    
    # Push to git first (before publishing)
    if ($Git) {
        Push-Git
    }
    
    $publishSuccess = $true
    
    # Publish to GitHub Releases
    if ($Github) {
        $githubSuccess = Publish-GitHubRelease -projectName $projectName -newVersion $newVersion -outputBinDir $outputBinDir -repo $Repo
        if (-not $githubSuccess) { $publishSuccess = $false }
    }
    
    # Publish to NuGet
    if ($Nuget) {
        $nugetSuccess = Publish-NuGet -projectName $projectName -newVersion $newVersion -outputBinDir $outputBinDir
        if (-not $nugetSuccess) { $publishSuccess = $false }
    }
    
    # Publish to Docker Hub
    if ($Docker) {
        $dockerSuccess = Publish-DockerHub -projectName $projectName -newVersion $newVersion -buildConfigs $buildConfigs -repo $Repo
        if (-not $dockerSuccess) { $publishSuccess = $false }
    }
    
    # Publish to GHCR
    if ($Ghcr) {
        $ghcrSuccess = Publish-GHCR -projectName $projectName -newVersion $newVersion -buildConfigs $buildConfigs -repo $Repo
        if (-not $ghcrSuccess) { $publishSuccess = $false }
    }
    
         if ($publishSuccess) {
         Write-Host "All publishing operations completed successfully!" -ForegroundColor Green
     }
     else {
         Write-Host "Some publishing operations failed." -ForegroundColor Yellow
     }
    
    return $publishSuccess
}

# Main execution logic
Write-Host "Debug - Parameters received:"
Write-Host "  Version: '$Version'"
Write-Host "  Arch: '$Arch'"
Write-Host "  Release: $Release"
Write-Host "  Debug: $Debug"
Write-Host "  Git: $Git"
Write-Host "  Docker: $Docker"
Write-Host "  Publish: $Publish"
Write-Host "  Github: $Github"
Write-Host "  Ghcr: $Ghcr"
Write-Host "  Nuget: $Nuget"
Write-Host "  Repo: '$Repo'"


# Always build first
Write-Host "Building project..."
$buildSuccess = Build-Project -Version $Version -Arch $Arch -Release:$Release -Debug:$Debug -Git:$Git -Docker:$Docker
if (-not $buildSuccess) {
    Write-Error "Build failed"
    exit 1
}

# Then optionally publish
if ($Publish) {
    Publish-Project -Version $Version -Arch $Arch -Nuget:$Nuget -Github:$Github -Git:$Git -Repo $Repo -Release:$Release -Debug:$Debug -Docker:$Docker -Ghcr:$Ghcr
}