param (
    [Parameter(Position=0, Mandatory=$false)]
    [string[]]$Actions = @()
)

# Import Bluscream helper functions (must come first)
. "$PSScriptRoot/powershell/bluscream.ps1"
# Import the shared steps logic (depends on bluscream.ps1)
. "$PSScriptRoot/powershell/steps.ps1"

# --- Update function definitions ---
function Update-Pip {
    param (
        [string]$bin = "python"
    )
    try {
        Set-Title "Updating $bin pip"
        Invoke-Expression "$bin -m pip install --upgrade pip wheel setuptools"
        Set-Title "Updating $bin pip packages"
        $installedPackages = Invoke-Expression "$bin -m pip list --format=freeze"
        foreach ($package in $installedPackages) {
            $packageName = $package.Split("==")[0]
            & $bin -m pip install --upgrade $packageName
        }
        return $true
    }
    catch {
        Write-Error $_.Exception.Message
        return $false
    }
}
function Update-Npm {
    try {
        Set-Title 'Updating npm'
        $outdatedRaw = & npm outdated --json 2>$null
        $outdatedPackages = $null
        if ($outdatedRaw -and $outdatedRaw.Trim().StartsWith('{')) {
            try {
                $outdatedPackages = $outdatedRaw | ConvertFrom-Json
            } catch {
                Write-Host "npm outdated output is not valid JSON. Skipping npm update."
                return $true
            }
        } else {
            Write-Host "No outdated npm packages found or output is not JSON."
            return $true
        }
        foreach ($packageName in $outdatedPackages.PSObject.Properties.Name) {
            & npm install $packageName@latest
        }
        return $true
    }
    catch {
        Write-Error $_.Exception.Message
        return $false
    }
}
function Update-Scoop {
    try {
        Set-Title 'Updating scoop'
        scoop install git
        scoop update * -g
        return $true
    }
    catch {
        Write-Error $_.Exception.Message
        Write-Warning "Run 'scoop update * -g' manually"
        return $false
    }
}
function Update-Chocolatey {
    try {
        Set-Title 'Updating chocolatey'
        choco upgrade all --accept-license --yes --allowunofficial --install-if-not-installed --ignorechecksum
        return $true
    }
    catch {
        Write-Error $_.Exception.Message
        return $false
    }
}
function Update-Winget {
    try {
        Set-Title 'Updating winget'
        try {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name Microsoft.WinGet.Client
            Import-Module -Name Microsoft.WinGet.Client
            Get-WinGetPackage | Where-Object Source -eq winget | Update-WinGetPackage
        } catch {
            Write-Host -ForegroundColor Orange "Failed to update winget through Powershell module"
        }
        try {
            $cmd = "winget upgrade --all --accept-package-agreements --accept-source-agreements --verbose"
            Write-Host $cmd
            Start-Process cmd.exe -ArgumentList "/c $cmd" -WindowStyle Normal
        } catch {
            Write-Host -ForegroundColor Orange "Failed to update winget through winget.exe"
        }
        return $true
    }
    catch {
        Write-Error $_.Exception.Message
        return $false
    }
}
function Update-Windows {
    try {
        Set-Title 'Updating windows'
        Install-Module PSWindowsUpdate -force
        Import-Module PSWindowsUpdate
        Get-Command -module PSWindowsUpdate  
        Get-WUInstall -IgnoreUserInput -Acceptall -Download -Install -Verbose
        try {
            Add-WUServiceManager -MicrosoftUpdate -Confirm:$false
        } catch {
            Write-Host "Add-WUServiceManager -MicrosoftUpdate failed or already present."
        }
        try {
            Add-WUServiceManager -ServiceID "9482f4b4-e343-43b6-b170-9a65bc822c77" -Confirm:$false
        } catch {
            Write-Host "Add-WUServiceManager -ServiceID failed or already present."
        }
        Get-WindowsUpdate -Install -MicrosoftUpdate -AcceptAll -IgnoreReboot
        return $true
    }
    catch {
        Write-Error $_.Exception.Message
        return $false
    }
}
function Test-CommandExists {
    param(
        [string]$Command
    )
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# Define update steps
$possibleSteps["update"] = @{
    pip = @{
        Description = "Update pip and all Python packages"
        Code = {
            $pip_success = $true
            foreach ($py in @("python", "python2", "python3")) {
                if (Test-CommandExists $py) {
                    $pip_success = $pip_success -and (Update-Pip $py)
                } else {
                    Write-Host "$py not found, skipping pip update for $py."
                }
            }
            if (-not $pip_success) { Write-Host "Failed to update pip" -ForegroundColor Red }
        }
    }
    npm = @{
        Description = "Update npm and all global npm packages"
        Code = {
            $npm_success = Update-Npm
            if (-not $npm_success) { Write-Host "Failed to update npm" -ForegroundColor Red }
        }
    }
    scoop = @{
        Description = "Update scoop and all scoop apps"
        Code = {
            $scoop_success = Update-Scoop
            if (-not $scoop_success) { Write-Host "Failed to update scoop" -ForegroundColor Red }
        }
    }
    chocolatey = @{
        Description = "Update chocolatey and all choco packages"
        Code = {
            $chocolatey_success = Update-Chocolatey
            if (-not $chocolatey_success) { Write-Host "Failed to update chocolatey" -ForegroundColor Red }
        }
    }
    winget = @{
        Description = "Update winget and all winget packages"
        Code = {
            $winget_success = Update-Winget
            if (-not $winget_success) { Write-Host "Failed to update winget" -ForegroundColor Red }
        }
    }
    windows = @{
        Description = "Update Windows via PSWindowsUpdate"
        Code = {
            $windows_success = Update-Windows
            if (-not $windows_success) { Write-Host "Failed to update windows" -ForegroundColor Red }
        }
    }
}

$possibleSteps["meta"] = @{
    all = @{
        Description = "Update everything"
        Actions = $possibleSteps["update"].Keys
    }
    default = @{
        Description = "Default update set"
        Actions = @("elevate", "scoop", "chocolatey", "winget", "windows")
    }
}

# Expand actions (handle meta-actions)
$actionsToRun = Expand-Steps -Steps $possibleSteps -Actions $Actions

Write-Host "The following actions will be run:" -ForegroundColor Cyan

# Run the steps
Run-Steps -Steps $possibleSteps -ActionsToRun $actionsToRun
