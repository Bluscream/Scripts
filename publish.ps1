# Publish script that uses the Publish-Module
# This eliminates parameter passing issues while keeping flexibility

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
    [switch]$Ghcr,
    [switch]$SkipBuild
)

# Import the module
Import-Module "D:\Scripts\powershell\Publish-Module.psm1" -Force

# Debug output
Write-Host "Debug - Parameters received:"
Write-Host "  Version: '$Version'"
Write-Host "  Arch: '$Arch'"
Write-Host "  Nuget: $Nuget"
Write-Host "  Github: $Github"
Write-Host "  Git: $Git"
Write-Host "  Repo: '$Repo'"
Write-Host "  Release: $Release"
Write-Host "  Debug: $Debug"
Write-Host "  Docker: $Docker"
Write-Host "  Ghcr: $Ghcr"
Write-Host "  SkipBuild: $SkipBuild"

# Call Publish-Project with the provided parameters
Publish-Project -Version $Version -Arch $Arch -Nuget:$Nuget -Github:$Github -Git:$Git -Repo $Repo -Release:$Release -Debug:$Debug -Docker:$Docker -Ghcr:$Ghcr -SkipBuild:$SkipBuild
