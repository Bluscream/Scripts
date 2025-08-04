# Build script that uses the Publish-Module
# This eliminates parameter passing issues while keeping flexibility

param(
    [string]$Version = "",
    [string]$Arch = "win-x64",
    [switch]$Release,
    [switch]$Debug,
    [switch]$Git,
    [switch]$Docker
)

# Import the module
Import-Module "D:\Scripts\powershell\Publish-Module.psm1" -Force

# Call Build-Project with the provided parameters
Build-Project -Version $Version -Arch $Arch -Release:$Release -Debug:$Debug -Git:$Git -Docker:$Docker 