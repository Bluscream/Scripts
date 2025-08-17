# Consolidated build and publish script
# Combines all functionality from Publish-Module.psm1 with a -Publish flag

param(
    [string]$Version = "",
    [string[]]$Arch = @("win-x64", "win-x86"),
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
        [Parameter(Mandatory = $true)]
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
                }
                catch {
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
    }
    else {
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

function Clear-BuildArtifacts {
    param(
        [string]$ProjectDir,
        [string]$OutputBinDir
    )
    
    Write-Host "Performing comprehensive build cleanup..." -ForegroundColor Yellow
    
    # Kill any running dotnet processes
    Kill-ProcessesByName -Names @("dotnet")
    
    # Run dotnet clean
    Write-Host "Running dotnet clean..."
    dotnet clean
    if ($LASTEXITCODE -eq 0) {
        Write-Host "dotnet clean completed successfully" -ForegroundColor Green
    }
    else {
        Write-Host "dotnet clean completed with warnings" -ForegroundColor Yellow
    }
    
    # Remove bin and obj directories completely
    $directoriesToRemove = @(
        $OutputBinDir,
        "$ProjectDir/obj",
        "$ProjectDir/bin"
    )
    
    foreach ($dir in $directoriesToRemove) {
        if (Test-Path $dir) {
            Write-Host "Removing directory: $dir"
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $dir)) {
                Write-Host "Successfully removed: $dir" -ForegroundColor Green
            }
            else {
                Write-Host "Failed to remove: $dir" -ForegroundColor Red
            }
        }
    }
    
    # Recreate the output bin directory
    if (-not (Test-Path $OutputBinDir)) {
        New-Item -ItemType Directory -Path $OutputBinDir -Force | Out-Null
        Write-Host "Recreated output directory: $OutputBinDir" -ForegroundColor Green
    }
    
    Write-Host "Build cleanup completed" -ForegroundColor Green
}

function Dotnet-Publish {
    param(
        [string]$Config,
        [string]$Arch,
        [string]$ProjectFramework,
        [string]$AssemblyName,
        [ValidateSet("DLL", "FrameworkExe", "StandaloneExe")]
        [string]$BuildType,
        [switch]$Clean
    )
    
    Write-Host "Building $BuildType for $Config on $arch..."
    
    if ($Clean) {
        Write-Host "Running dotnet clean..."
        dotnet clean
        if ($LASTEXITCODE -eq 0) {
            Write-Host "dotnet clean completed successfully" -ForegroundColor Green
        }
        else {
            Write-Host "dotnet clean completed with warnings" -ForegroundColor Yellow
        }
    }
    
    # Build the dotnet publish command
    $publishArgs = @(
        "publish",
        "-c", $Config,
        "-r", $Arch
    )
    
    # Add build type specific arguments
    switch ($BuildType) {
        "DLL" {
            # Basic DLL build - no additional args needed
        }
        "FrameworkExe" {
            $publishArgs += @("--self-contained", "false")
        }
        "StandaloneExe" {
            $publishArgs += @(
                "--self-contained", "true",
                "/p:PublishSingleFile=true",
                "/p:IncludeAllContentForSelfExtract=true"
            )
        }
    }
    
    # Add release optimizations
    if ($Config -eq "Release") {
        $publishArgs += @(
            "/p:OptimizeImplicitlyTriggeredBuild=true",
            "/p:EnableCompressionInSingleFile=true",
            "/p:DebugType=None",
            "/p:DebugSymbols=false"
        )
        
        # Additional optimizations for standalone builds
        if ($BuildType -eq "StandaloneExe") {
            $publishArgs += @(
                "/p:PublishTrimmed=true",
                "/p:TrimMode=link",
                "/p:EnableUnsafeBinaryFormatterSerialization=false",
                "/p:EnableUnsafeUTF7Encoding=false",
                "/p:EventSourceSupport=false",
                "/p:HttpActivityPropagationSupport=false",
                "/p:InvariantGlobalization=true",
                "/p:MetadataUpdaterSupport=false"
                # "/p:UseSystemTextJson=false"
            )
        }
    }
    
    # Execute dotnet publish and capture output
    $publishOutput = dotnet $publishArgs 2>&1
    $publishExitCode = $LASTEXITCODE
    
    if ($publishExitCode -ne 0) {
        Write-Host "Error during $BuildType dotnet publish (Exit code: $publishExitCode)" -ForegroundColor Red
        return $null
    }
    
    # Try to extract output path from dotnet publish output
    $outputPath = $null
    
    # Look for the publish path (line with -> that ends with \publish\)
    $lines = $publishOutput -split "`n"
    foreach ($line in $lines) {
        if ($line -match ".* -> (.+\\publish\\)$") {
            $outputPath = $matches[1].Trim()
            Write-Host "Extracted output path from $BuildType publish: $outputPath" -ForegroundColor Green
            return $outputPath
        }
    }
    
    # Fallback: look for any line with -> that contains publish
    foreach ($line in $lines) {
        if ($line -match ".* -> (.+publish.+)$") {
            $outputPath = $matches[1].Trim()
            Write-Host "Extracted output path from $BuildType publish (fallback): $outputPath" -ForegroundColor Green
            return $outputPath
        }
    }
    
    Write-Host "Could not extract output path from $BuildType publish output" -ForegroundColor Yellow
    Write-Host "Publish output: $publishOutput"
    return $null
}

function Find-BuiltFile {
    param(
        [string]$Config,
        [string]$Arch,
        [string]$ProjectFramework,
        [string]$AssemblyName,
        [string]$FileExtension,
        [string]$FileType = "file",
        [bool]$IsPublish = $false
    )
    $searchPaths = @()
    # Adjust search paths based on $IsPublish
    if ($IsPublish) {
        $searchPaths = @(
            "bin/$Config/$ProjectFramework/$Arch/publish/",
            "bin/$Config/$Arch/publish/",
            "bin/$Config/publish/",
            "bin/"
        )
    }
    else {
        $searchPaths = @(
            "bin/$Config/$ProjectFramework/$Arch/",
            "bin/$Config/$Arch/",
            "bin/$Config/",
            "bin/"
        )
    }

    $filePattern = "$AssemblyName$FileExtension"
    Write-Host "Looking for $FileType $filePattern (IsPublish: $IsPublish)"

    foreach ($path in $searchPaths) {
        $fullPath = Join-Path (Join-Path $ProjectDir $path) "$AssemblyName$FileExtension"
        Write-Host "Searching path: $fullPath"
        if (Test-Path $fullPath) {
            $foundFile = Get-Item $fullPath
            if ($foundFile) {
                Write-Host "Found $FileType at: $($foundFile.FullName)" -ForegroundColor Green
                return $foundFile
            }
        }
    }
    
    # If file not found, provide debugging information
    # Write-Host "$FileType not found" -ForegroundColor Red
    # Write-Host "Debug: Listing all files in bin/$Config/ directory:"
    # if (Test-Path "bin/$Config/") {
    #     Get-ChildItem -Path "bin/$Config/" -Recurse | ForEach-Object { Write-Host "  - $($_.FullName)" }
    # }
    
    # # Also check specifically in the publish directory
    # $publishPath = "bin/$Config/$ProjectFramework/$Arch/publish/"
    # if (Test-Path $publishPath) {
    #     Write-Host "Debug: Listing all files in publish directory ($publishPath):"
    #     Get-ChildItem -Path $publishPath | ForEach-Object { Write-Host "  - $($_.Name)" }
    # }

    Write-Host "$FileType $AssemblyName$FileExtension not found" -ForegroundColor Red
    
    return $null
}

function Commit-Git {
    Write-Host "Committing changes to git..."

    if (-not (Test-Path ".git")) {
        Write-Host "Initializing new git repository..."
        git init        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Git repository initialized successfully" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to initialize git repository" -ForegroundColor Red
            return $false
        }
        git branch -M main
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Git branch set to main" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to set git branch to main" -ForegroundColor Red
        }
    }

    if (-not (Test-Path ".gitignore")) {
        Write-Host "Creating .gitignore file..."
        $gitignore_template | Out-File -Encoding utf8 ".gitignore"
        if ($LASTEXITCODE -eq 0) {
            Write-Host ".gitignore file created successfully" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to create .gitignore file" -ForegroundColor Red
        }
    }
    
    Write-Host "Adding files to git..."
    git add .
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Files added to git successfully" -ForegroundColor Green
    }
    else {
        Write-Host "Failed to add files to git" -ForegroundColor Red
        return $false
    }
    
    $datetime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "Committing changes..."
    git commit -m "Build at $datetime"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Changes committed successfully" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "Failed to commit changes" -ForegroundColor Red
        return $false
    }
}

function Push-Git {
    Write-Host "Pushing changes to git..."
    git push
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Changes pushed to git successfully" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "Failed to push changes to git" -ForegroundColor Red
        return $false
    }
}

function Start-DockerIfNeeded {
    Write-Host "Checking Docker status..."
    
    # Check if Docker daemon is accessible
    try {
        docker info --format "{{.ServerVersion}}" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Docker daemon is running" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Host "Docker daemon not accessible" -ForegroundColor Yellow
    }
    
    Write-Host "Docker daemon not running. Checking Docker service..." -ForegroundColor Yellow
    
    # Check and start Docker Windows service if needed
    try {
        $dockerService = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
        if ($dockerService) {
            if ($dockerService.Status -ne "Running") {
                Write-Host "Starting Docker service (com.docker.service)..." -ForegroundColor Yellow
                Start-Service -Name "com.docker.service" -ErrorAction Stop
                Write-Host "Docker service started successfully" -ForegroundColor Green
                
                # Wait a moment for the service to fully start
                Start-Sleep -Seconds 3
                
                # Check if Docker daemon is now accessible
                try {
                    docker info --format "{{.ServerVersion}}" 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Docker daemon is now running after service start" -ForegroundColor Green
                        return $true
                    }
                }
                catch {
                    Write-Host "Docker daemon still not accessible after service start" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Docker service is already running" -ForegroundColor Green
            }
        }
        else {
            Write-Host "Docker service (com.docker.service) not found" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Failed to manage Docker service: $_" -ForegroundColor Yellow
    }
    
    Write-Host "Attempting to start Docker Desktop..." -ForegroundColor Yellow
    
    # Try to start Docker Desktop application
    $dockerDesktopPaths = @(
        "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
        "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
    )
    
    $dockerStarted = $false
    foreach ($path in $dockerDesktopPaths) {
        if (Test-Path $path) {
            Write-Host "Starting Docker Desktop from: $path"
            try {
                Start-Process -FilePath $path -ErrorAction Stop
                $dockerStarted = $true
                break
            }
            catch {
                Write-Host "Failed to start Docker Desktop from $path : $_" -ForegroundColor Yellow
            }
        }
    }
    
    if (-not $dockerStarted) {
        Write-Host "Could not find Docker Desktop executable. Trying to start via Start-Process..." -ForegroundColor Yellow
        try {
            Start-Process "Docker Desktop" -ErrorAction Stop
            $dockerStarted = $true
        }
        catch {
            Write-Host "Failed to start Docker Desktop: $_" -ForegroundColor Yellow
        }
    }
    
    if ($dockerStarted) {
        Write-Host "Docker Desktop starting... waiting for daemon to be ready..." -ForegroundColor Yellow
        
        # Wait for Docker daemon to be ready (up to 60 seconds)
        $maxWaitTime = 60
        $waitTime = 0
        $interval = 2
        
        while ($waitTime -lt $maxWaitTime) {
            Start-Sleep -Seconds $interval
            $waitTime += $interval
            
            try {
                docker info --format "{{.ServerVersion}}" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Docker daemon is now ready!" -ForegroundColor Green
                    return $true
                }
            }
            catch {
                # Continue waiting
            }
            
            Write-Host "Still waiting for Docker daemon... ($waitTime/$maxWaitTime seconds)" -ForegroundColor Yellow
        }
        
        Write-Host "Docker daemon did not start within $maxWaitTime seconds" -ForegroundColor Red
        return $false
    }
    
    Write-Host "Failed to start Docker Desktop" -ForegroundColor Red
    return $false
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
    
    # Ensure Docker is running before proceeding
    if (-not (Start-DockerIfNeeded)) {
        Write-Host "Docker is not available. Skipping Docker image builds." -ForegroundColor Red
        return
    }
    
    # Get GitHub username for the source label
    $githubUsername = Get-Username -Service "github"
    if (-not $githubUsername) {
        Write-Warning "Could not determine GitHub username for Docker source label"
        $githubUsername = "unknown"
    }
    
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
LABEL org.opencontainers.image.source=https://github.com/$githubUsername/$repo
ENTRYPOINT ["dotnet", "$projectName.dll"]
"@
        $dockerfilePath = Join-Path $projectDir "Dockerfile"
        $dockerfileContent | Out-File -FilePath $dockerfilePath -Encoding UTF8
        $dockerfiles = @(Get-Item $dockerfilePath)
        Write-Host "Created default Dockerfile at $dockerfilePath"
    }
    
    # Process each Dockerfile to ensure it has the source label
    foreach ($dockerfile in $dockerfiles) {
        $dockerfileContent = Get-Content $dockerfile.FullName -Raw
        $sourceLabel = "LABEL org.opencontainers.image.source=https://github.com/$githubUsername/$repo"
        
        # Check if the source label already exists
        if ($dockerfileContent -notmatch [regex]::Escape("org.opencontainers.image.source")) {
            Write-Host "Adding source label to Dockerfile: $($dockerfile.Name)"
            
            # Find the best place to add the label - after FROM statements but before ENTRYPOINT/CMD
            $lines = Get-Content $dockerfile.FullName
            $newLines = @()
            $labelAdded = $false
            $lastFromIndex = -1
            
            # First pass: find the last FROM statement
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^\s*FROM\s+") {
                    $lastFromIndex = $i
                }
            }
            
            # Second pass: add the label after the last FROM statement
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $newLines += $lines[$i]
                
                # Add the label after the last FROM statement
                if (-not $labelAdded -and $i -eq $lastFromIndex) {
                    $newLines += $sourceLabel
                    $labelAdded = $true
                }
            }
            
            # If no FROM statement found, add at the beginning (though this shouldn't happen)
            if (-not $labelAdded) {
                $newLines = @($sourceLabel) + $newLines
            }
            
            # Write the updated content back to the file
            $newLines | Out-File -FilePath $dockerfile.FullName -Encoding UTF8
            Write-Host "Added source label to $($dockerfile.Name)" -ForegroundColor Green
        }
        else {
            Write-Host "Source label already exists in $($dockerfile.Name)" -ForegroundColor Yellow
        }
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
                  
                # For release builds, also tag as plain "latest"
                if ($configToBuild -eq "Release") {
                    $plainLatestTag = "${dockerImageName}:latest"
                    docker tag $dockerTag $plainLatestTag
                    Write-Host "Tagged as plain latest: $plainLatestTag" -ForegroundColor Green
                }
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
    $assets = Get-ChildItem -Path $outputBinDir -File | Where-Object { $_.Extension -match '\.(exe|dll|nupkg)$' }
    
    Write-Host "Found $($assets.Count) assets to upload:"
    foreach ($asset in $assets) {
        $sizeMB = [Math]::Round($asset.Length / 1MB, 2)
        
        # Try multiple methods to calculate MD5 hash
        $hash = "N/A"
        try {
            # Method 1: Use Get-FileHash with MD5 (PowerShell 5.1+)
            $hashResult = Get-FileHash -Path $asset.FullName -Algorithm MD5 -ErrorAction Stop
            if ($hashResult -and $hashResult.Hash) {
                $hash = $hashResult.Hash
                Write-Host "  MD5 calculated using Get-FileHash" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "  Get-FileHash failed, trying alternative method..." -ForegroundColor DarkGray
            try {
                # Method 2: Use .NET MD5 class directly
                $md5 = [System.Security.Cryptography.MD5]::Create()
                $fileStream = [System.IO.File]::OpenRead($asset.FullName)
                $hashBytes = $md5.ComputeHash($fileStream)
                $fileStream.Close()
                $md5.Dispose()
                $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
                Write-Host "  MD5 calculated using .NET MD5 class" -ForegroundColor DarkGray
            }
            catch {
                Write-Host "  .NET MD5 calculation failed, trying PowerShell MD5..." -ForegroundColor DarkGray
                try {
                    # Method 3: Use PowerShell's built-in hash calculation
                    $fileContent = Get-Content -Path $asset.FullName -Raw -Encoding Byte
                    $md5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
                    $hashBytes = $md5.ComputeHash($fileContent)
                    $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
                    $md5.Dispose()
                    Write-Host "  MD5 calculated using PowerShell MD5" -ForegroundColor DarkGray
                }
                catch {
                    Write-Host "  All MD5 calculation methods failed for $($asset.Name)" -ForegroundColor Yellow
                    $hash = "N/A"
                }
            }
        }
        
        # Generate a color from the MD5 hash (use first 6 hex digits, map to ConsoleColor)
        $colorMap = @(
            'Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta', 'DarkYellow', 'Gray',
            'DarkGray', 'Blue', 'Green', 'Cyan', 'Red', 'Magenta', 'Yellow', 'White'
        )
        if ($hash -ne "N/A") {
            $colorIndex = [Convert]::ToInt32($hash.Substring(0, 2), 16) % $colorMap.Count
            $color = $colorMap[$colorIndex]
        }
        else {
            $color = "Gray"
        }
        Write-Host ("  - {0} [{1} MB] (MD5: {2})" -f $asset.Name, $sizeMB, $hash) -ForegroundColor $color
    }
    
    if ($assets.Count -eq 0) {
        Write-Warning "No assets found in $outputBinDir. Checking if directory exists and has content..."
        if (Test-Path $outputBinDir) {
            Write-Host "Directory exists. Contents:"
            Get-ChildItem -Path $outputBinDir -Recurse | ForEach-Object { Write-Host "  - $($_.Name) ($($_.FullName))" }
        }
        else {
            Write-Host "Directory does not exist: $outputBinDir"
        }
        return $false
    }
    $uploadJobs = @()
    
    foreach ($asset in $assets) {
        Write-Host "Starting upload for asset: $($asset.Name)"
        $job = Start-Job -ScriptBlock {
            param($assetPath, $version, $repo)
            try {
                $output = gh release upload $version $assetPath --repo $repo 2>&1
                $exitCode = $LASTEXITCODE
                return @{
                    Name     = [System.IO.Path]::GetFileName($assetPath)
                    ExitCode = $exitCode
                    Output   = $output
                }
            }
            catch {
                return @{
                    Name     = [System.IO.Path]::GetFileName($assetPath)
                    ExitCode = 1
                    Output   = $_.Exception.Message
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
    
    # Ensure Docker is running before proceeding
    if (-not (Start-DockerIfNeeded)) {
        Write-Host "Docker is not available. Skipping Docker Hub publishing." -ForegroundColor Red
        return $false
    }
    
    # Get Docker username
    $dockerUsername = Get-Username -Service "docker"
    if (-not $dockerUsername) {
        return $false
    }
    
    $success = $true
    foreach ($config in $buildConfigs) {
        $configTag = if ($config -eq "Release") { "release" } else { "debug" }
        # Use repo name if provided, otherwise fall back to project name
        $imageBaseName = if ($repo) { $repo } else { $projectName.ToLower() }
        $localImageName = $imageBaseName.ToLower()
        $dockerImageName = "$dockerUsername/$imageBaseName"
        $dockerTag = "${dockerImageName}:$configTag-$newVersion"
        $dockerLatestTag = "${dockerImageName}:$configTag-latest"
         
        Write-Host "Tagging local image for Docker Hub: $dockerTag"
        docker tag "${localImageName}:$configTag-$newVersion" $dockerTag
        docker tag "${localImageName}:$configTag-latest" $dockerLatestTag
          
        # For release builds, also tag the plain "latest" tag
        if ($config -eq "Release") {
            $plainLatestTag = "${dockerImageName}:latest"
            docker tag "${localImageName}:$configTag-$newVersion" $plainLatestTag
        }
        
        Write-Host "Pushing to Docker Hub: $dockerTag"
        docker push $dockerTag
        Write-Host "Pushing to Docker Hub: $dockerLatestTag"
        docker push $dockerLatestTag
         
        # For release builds, also push plain "latest" tag
        if ($config -eq "Release") {
            $plainLatestTag = "${dockerImageName}:latest"
            Write-Host "Pushing to Docker Hub: $plainLatestTag"
            docker push $plainLatestTag
        }
        
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
    
    # Ensure Docker is running before proceeding
    if (-not (Start-DockerIfNeeded)) {
        Write-Host "Docker is not available. Skipping GHCR publishing." -ForegroundColor Red
        return $false
    }
    
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
        # Use repo name if provided, otherwise fall back to project name
        $imageBaseName = if ($repo) { $repo } else { $projectName.ToLower() }
        $localImageName = $imageBaseName.ToLower()
        $ghcrImageName = "ghcr.io/$githubUsername/$imageBaseName"
        $ghcrTag = "${ghcrImageName}:$configTag-$newVersion"
        $ghcrLatestTag = "${ghcrImageName}:$configTag-latest"
         
        Write-Host "Tagging local image for GHCR: $ghcrTag"
        docker tag "${localImageName}:$configTag-$newVersion" $ghcrTag
        docker tag "${localImageName}:$configTag-latest" $ghcrLatestTag
          
        # For release builds, also tag the plain "latest" tag
        if ($config -eq "Release") {
            $plainLatestTag = "${ghcrImageName}:latest"
            docker tag "${localImageName}:$configTag-$newVersion" $plainLatestTag
        }
        
        Write-Host "Pushing to GHCR: $ghcrTag"
        docker push $ghcrTag
        Write-Host "Pushing to GHCR: $ghcrLatestTag"
        docker push $ghcrLatestTag
         
        # For release builds, also push plain "latest" tag
        if ($config -eq "Release") {
            $plainLatestTag = "${ghcrImageName}:latest"
            Write-Host "Pushing to GHCR: $plainLatestTag"
            docker push $plainLatestTag
        }
        
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
        [string[]]$Arch = @("win-x64", "win-x86"),
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

        # Determine architectures to build for
        $architectures = @()
        if ($Arch -and $Arch.Count -gt 0) {
            $architectures = $Arch
        }
        elseif ($projectRIDNode -and $projectRIDNode.RuntimeIdentifier) {
            $architectures = @($projectRIDNode.RuntimeIdentifier)
        }
        elseif ($projectRIDsNode -and $projectRIDsNode.RuntimeIdentifiers) {
            $architectures = $projectRIDsNode.RuntimeIdentifiers -split ';'
        }
        else {
            $architectures = @('win-x64', 'win-x86')
        }
        Write-Host "Building for architectures: $($architectures -join ', ')"

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

        # Perform comprehensive cleanup before building
        Clear-BuildArtifacts -ProjectDir $projectDir -OutputBinDir $outputBinDir

        $outputFrameworkExe = $null; $outputStandaloneExe = $null; $outputBinPath = $null
        
        # Build for each configuration and architecture combination
        foreach ($config in $buildConfigs) {
            foreach ($arch in $architectures) {
                Write-Host "Building for configuration: $config, architecture: $arch"
                
                # Determine suffix based on configuration and architecture
                $configSuffix = if ($config -eq "Release") { ".release" } else { ".debug" }
                $outputFrameworkSuffixWithConfig = ".$projectFramework.$arch$configSuffix.exe"
                $outputSelfcontainedSuffixWithConfig = ".standalone.$arch$configSuffix.exe"
                $outputBinarySuffixWithConfig = ".$arch$configSuffix"
                
                # Build DLL
                $outputPath = Dotnet-Publish -Config $config -Arch $arch -ProjectFramework $projectFramework -AssemblyName $outputAssemblyName -BuildType "DLL"
                
                # Look for DLL in the extracted path first, then fall back to Find-BuiltFile
                $dllPath = $null
                if ($outputPath -and (Test-Path $outputPath)) {
                    $dllFile = Join-Path $outputPath "$outputAssemblyName.dll"
                    if (Test-Path $dllFile) {
                        $dllPath = Get-Item $dllFile
                        Write-Host "Found DLL in extracted path: $($dllPath.FullName)" -ForegroundColor Green
                    }
                }
                
                # Fall back to Find-BuiltFile if we couldn't find it in the extracted path
                if (-not $dllPath) {
                    Write-Host "Falling back to Find-BuiltFile for DLL..." -ForegroundColor Yellow
                    $dllPath = Find-BuiltFile -IsPublish:$true -Config $config -Arch $arch -ProjectFramework $projectFramework -AssemblyName $outputAssemblyName -FileExtension ".dll" -FileType "DLL"
                }
                
                if ($dllPath) {
                    $dllDest = Join-Path $outputBinDir "$outputAssemblyName$outputBinarySuffixWithConfig.dll"
                    Copy-Item $dllPath.FullName $dllDest -Force
                    Write-Host "DLL built successfully: $dllDest" -ForegroundColor Green
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "Error during dotnet publish $($LASTEXITCODE)" -ForegroundColor Red
                }

                # Build Framework-dependent EXE
                $outputPath = Dotnet-Publish -Config $config -Arch $arch -ProjectFramework $projectFramework -AssemblyName $outputAssemblyName -BuildType "FrameworkExe"
                
                # Look for EXE in the extracted path first, then fall back to Find-BuiltFile
                $outputFrameworkExe = $null
                if ($outputPath -and (Test-Path $outputPath)) {
                    $exeFile = Join-Path $outputPath "$outputAssemblyName.exe"
                    if (Test-Path $exeFile) {
                        $outputFrameworkExe = Get-Item $exeFile
                        Write-Host "Found framework EXE in extracted path: $($outputFrameworkExe.FullName)" -ForegroundColor Green
                    }
                }
                
                # Fall back to Find-BuiltFile if we couldn't find it in the extracted path
                if (-not $outputFrameworkExe) {
                    Write-Host "Falling back to Find-BuiltFile for framework EXE..." -ForegroundColor Yellow
                    $outputFrameworkExe = Find-BuiltFile -IsPublish:$true -Config $config -Arch $arch -ProjectFramework $projectFramework -AssemblyName $outputAssemblyName -FileExtension ".exe" -FileType "framework EXE"
                }
                
                $fwExeName = "$outputAssemblyName$outputFrameworkSuffixWithConfig"
                if ($outputFrameworkExe) {
                    Copy-Item $outputFrameworkExe.FullName (Join-Path $outputBinDir $fwExeName) -Force
                    Write-Host "Framework-dependent EXE built successfully: $fwExeName" -ForegroundColor Green
                }
                                
                # Build Self-contained EXE
                $outputPath = Dotnet-Publish -Config $config -Arch $arch -ProjectFramework $projectFramework -AssemblyName $outputAssemblyName -BuildType "StandaloneExe"
                
                # Look for EXE in the extracted path first, then fall back to Find-BuiltFile
                $outputStandaloneExe = $null
                if ($outputPath -and (Test-Path $outputPath)) {
                    $exeFile = Join-Path $outputPath "$outputAssemblyName.exe"
                    if (Test-Path $exeFile) {
                        $outputStandaloneExe = Get-Item $exeFile
                        Write-Host "Found standalone EXE in extracted path: $($outputStandaloneExe.FullName)" -ForegroundColor Green
                    }
                }
                
                # Fall back to Find-BuiltFile if we couldn't find it in the extracted path
                if (-not $outputStandaloneExe) {
                    Write-Host "Falling back to Find-BuiltFile for standalone EXE..." -ForegroundColor Yellow
                    $outputStandaloneExe = Find-BuiltFile -IsPublish:$true -Config $config -Arch $arch -ProjectFramework $projectFramework -AssemblyName $outputAssemblyName -FileExtension ".exe" -FileType "standalone EXE"
                }
                
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
        }

        if ($Git) {
            $commitSuccess = Commit-Git
            if (-not $commitSuccess) {
                Write-Host "Git commit failed" -ForegroundColor Red
            }
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
        [string[]]$Arch = @("win-x64", "win-x86"),
        [switch]$Nuget,
        [switch]$Github,
        [switch]$Git,
        [string]$Repo,
        [switch]$Release,
        [switch]$Debug,
        [switch]$Docker,
        [switch]$Ghcr
    
    )
    
    Write-Host "Publish-Project function called with:" -ForegroundColor Cyan
    Write-Host "  Github: $Github" -ForegroundColor Cyan
    Write-Host "  Repo: '$Repo'" -ForegroundColor Cyan
    Write-Host "  Release: $Release" -ForegroundColor Cyan
    Write-Host "  Debug: $Debug" -ForegroundColor Cyan
    
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
        $pushSuccess = Push-Git
        if (-not $pushSuccess) {
            Write-Host "Git push failed" -ForegroundColor Red
        }
    }
    
    $publishSuccess = $true
    
    # Publish to GitHub Releases
    if ($Github) {
        Write-Host "Publishing to GitHub Releases..." -ForegroundColor Cyan
        $githubSuccess = Publish-GitHubRelease -projectName $projectName -newVersion $newVersion -outputBinDir $outputBinDir -repo $Repo
        if (-not $githubSuccess) { 
            Write-Host "GitHub publishing failed!" -ForegroundColor Red
            $publishSuccess = $false 
        }
        else {
            Write-Host "GitHub publishing completed successfully!" -ForegroundColor Green
        }
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
Write-Host "  Arch: $($Arch -join ', ')"
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
    Write-Host "Starting publishing phase..." -ForegroundColor Cyan
    $publishResult = Publish-Project -Version $Version -Arch $Arch -Nuget:$Nuget -Github:$Github -Git:$Git -Repo $Repo -Release:$Release -Debug:$Debug -Docker:$Docker -Ghcr:$Ghcr
    if ($publishResult) {
        Write-Host "Publishing completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Host "Publishing failed!" -ForegroundColor Red
        exit 1
    }
}