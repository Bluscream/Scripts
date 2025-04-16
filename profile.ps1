Write-Host "Running '$PSCommandPath'..."
function Get-PSVersion {
    if (test-path variable:psversiontable) {$psversiontable.psversion} else {[version]"1.0.0.0"}
}

$PSVersion = Get-PSVersion
if ($PSVersion.Major -ge 6) {
    Import-Module Symlink
}
if ($PSVersion.Major -ge 7) {

    #f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module

    Import-Module -Name Microsoft.WinGet.CommandNotFound
    #f45873b3-b655-43a6-b217-97c00aa0db58

    Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1
    
    Import-Module DISM -SkipEditionCheck # -UseWindowsPowerShell 

} else {
    Write-Host "PowerShell $PSVersion"
    
    Import-Module DISM
}

# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

new-alias ytm youtube-music-control

Write-Host "Ran '$PSCommandPath'"
