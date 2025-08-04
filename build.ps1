# Build script - handles building and version management
# Publishing functionality has been moved to publish.ps1
# Git operations: commit in build.ps1, push in publish.ps1
# Docker operations: build images in build.ps1, push to registries in publish.ps1

param(
    [string]$Csproj,
    [string]$Version,
    [string]$Arch,
    [switch]$Release,
    [switch]$Debug,
    [switch]$Git,
    [switch]$Docker
)

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
*.TestResults/
TestResults/
"@

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

$ErrorActionPreference = 'Stop'

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
            exit 1
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
            Write-Host "DLL built successfully: $dllDest"
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
            Write-Host "Framework-dependent EXE built successfully: $fwExeName"
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
            Write-Host "Self-contained EXE built successfully: $scExeName"
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
    Write-Host "Docker flag: $Docker"
    if ($Docker) {
        Write-Host "Starting Docker image building..."
        Build-DockerImages
    }
    else {
        Write-Host "Docker building skipped (Docker flag not set)"
    }

    Pop-Location
}

function Build-DockerImages {
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
        
        # Build for each configuration
        foreach ($config in $buildConfigs) {
            $configSuffix = if ($config -eq "Release") { ".release" } else { ".debug" }
            
            # Build Docker image for Docker Hub
            $dockerImageName = "$projectName$configSuffix"
            $dockerTag = "${dockerImageName}:$newVersion"
            $dockerLatestTag = "${dockerImageName}:latest"
            
            Write-Host "Building Docker image: $dockerTag"
            docker build -f $dockerfile.FullName -t $dockerTag --build-arg CONFIGURATION=$config .
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Docker image built successfully: $dockerTag"
                
                # Tag as latest
                docker tag $dockerTag $dockerLatestTag
                Write-Host "Tagged as latest: $dockerLatestTag"
            }
            else {
                Write-Host "Failed to build Docker image: $dockerTag" -ForegroundColor Red
            }
        }
    }
} 