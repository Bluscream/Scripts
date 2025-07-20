param (
    [switch]$pip,
    [switch]$npm,
    [switch]$scoop,
    [switch]$chocolatey,
    [switch]$winget,
    [switch]$includeUnknown,
    [switch]$windows,
    [switch]$all,
    [switch]$default,
    [switch]$skipUAC = $false,
    [switch]$help,
    [ValidateSet('Lock', 'Shutdown', 'Reboot', 'Hibernate', 'SetPowerProfile')]
    [string]$CompleteAction,
    [int]$Delay =  0
)

$allByDefault = $false # Can set to true to update everything by default instead of showing help

function Print-Help { Write-Host @"
Usage: ./update.ps1 [options]
Options:
    -pip                : Update pip
    -npm                : Update npm
    -scoop              : Update scoop
    -chocolatey         : Update chocolatey
    -winget             : Update winget
    -includeUnknown     : Include unknown packages during winget upgrade
    -windowsUpdate      : Update Windows
    -all                : Update everything
    -default            : Update (scoop, chocolatey, winget, windows)
    -skipUAC            : Skip User Account Control prompt
    -CompleteAction     : Perform a complete action after updating (Lock, Shutdown, Reboot, Hibernate, SetPowerProfile=<PowerProfileID>)
    -Delay              : Delay before performing the complete action
    -help               : Display this help message

Examples:
    ./update.ps1 -all
    [ Will update everything ]
    ./update.ps1 -pip -npm
    [ Will update pip and npm ]
    ./update.ps1 -scoop -chocolatey -winget -windowsUpdate
    [ Will update scoop, chocolatey, winget and windows ]
    ./update.ps1 -CompleteAction SetPowerProfile=8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c -Delay 60
    [ Will set the power profile to High Performance after updating and wait for 60 seconds ]
    ./update.ps1 -help
    [ Will display this help message ]
"@
}

function Elevate-Script {
    if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
            $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
            Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine
            Exit
        }
    }
}
function Set-Title {
    param (
        [string]$message,
        [string]$color = 'Green'
    )
    $Host.UI.RawUI.WindowTitle = $message
    Write-Host $message -ForegroundColor $color
}
Function pause ($message) {
    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$message")
    }
    else {
        Write-Host "$message" -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}
function Execute-CompleteAction {
    param (
        [string]$action
    )

    switch ($action) {
        'Lock' {
            rundll32.exe user32.dll,LockWorkStation
            return $true
        }
        'Shutdown' {
            psshutdown.exe /s /t  0
            return $true
        }
        'Reboot' {
            psshutdown.exe /r /t  0
            return $true
        }
        'Hibernate' {
            rundll32.exe powrprof.dll,SetSuspendState  0,1,0
            return $true
        }
    }
    # if action starts with SetPowerProfile=, then set the power profile
    if ($action -match '^SetPowerProfile=(.*)') {
        $powerProfile = $matches[1]
        powercfg.exe /s $powerProfile
        return $true
    }
    return $false
}

function Update-Pip {
    param (
        [string]$bin
    )
    try {
        Set-Title "Updating $bin pip"
        iex "$bin -m pip install --upgrade pip wheel setuptools"
        Set-Title "Updating $bin pip packages"
        # Get a list of all installed packages
        $installedPackages = iex "$bin -m pip list --format=freeze"
    
        # Iterate over each package and upgrade it
        foreach ($package in $installedPackages) {
            # Extract the package name from the line
            $packageName = $package.Split("==")[0]
    
            # Upgrade the package
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
        # Get list of outdated packages
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
            # Add-WinGetSource -Name mysource -Argument "https://interal.powershellisfun.com/" -Type Microsoft.Rest -Verbose
            Get-WinGetPackage | Where-Object Source -eq winget | Update-WinGetPackage
        } catch {
            Write-Host -ForegroundColor Orange "Failed to update winget through Powershell module"
        }
        try {
            $cmd = "winget upgrade --all --accept-package-agreements --accept-source-agreements --verbose"
            if ($all -or $includeUnknown) {
                $cmd += " --include-unknown"
            }
            Write-Host $cmd
            Start-Process cmd.exe -ArgumentList "/c $cmd" -WindowStyle Normal
            # Invoke-Expression $cmd
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
        # Get-WindowsUpdate
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

# Only call Update-Pip for python executables that exist
function Test-CommandExists {
    param(
        [string]$Command
    )
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

if ($allByDefault -and $MyInvocation.BoundParameters.Count -eq 0) {
    $pip = $true
    $npm = $true
    $scoop = $true
    $chocolatey = $true
    $winget = $true
    $windows = $true
}
elseif ($help -or $MyInvocation.BoundParameters.Count -eq 0) {
    Print-Help
    exit
}

if (-Not $skipUAC) { Elevate-Script }

if ($all -or $default -or $scoop) { $scoop_success = Update-Scoop }

if ($all -or $default -or $chocolatey) { $chocolatey_success = Update-Chocolatey }

if ($all -or $default -or $windows) { $windows_success = Update-Windows }

if ($all -or $default -or $npm) { $npm_success = Update-Npm }

if ($all -or $default -or $pip) {
    $pip_success = $true
    foreach ($py in @("python", "python2", "python3")) {
        if (Test-CommandExists $py) {
            $pip_success = $pip_success -and (Update-Pip $py)
        } else {
            Write-Host "$py not found, skipping pip update for $py."
        }
    }
}

if ($all -or $default -or $winget) { $winget_success = Update-Winget }

if (!$scoop_success) { Write-Host "Failed to update scoop" -ForegroundColor Red }
if (!$chocolatey_success) { Write-Host "Failed to update chocolatey" -ForegroundColor Red }
if (!$winget_success) { Write-Host "Failed to update winget" -ForegroundColor Red }
if (!$windows_success) { Write-Host "Failed to update windows" -ForegroundColor Red }
if (!$npm_success) { Write-Host "Failed to update npm" -ForegroundColor Red }
if (!$pip_success) { Write-Host "Failed to update pip" -ForegroundColor Red }

if ($CompleteAction) {
    Set-Title "Complete action: $CompleteAction (Delay: $Delay s)"
    if ($Delay -gt 0) {
        Write-Host "Waiting for $Delay seconds before performing the complete action"
        Start-Sleep -Seconds $Delay
    }
    $completeActionSuccess = Execute-CompleteAction -action $CompleteAction
    if ($completeActionSuccess) { Write-Host "Complete action performed successfully" -ForegroundColor Green
    } else { Write-Host "Failed to perform complete action" -ForegroundColor Red }
}

if ($PauseBeforeExit) {
    pause "Press any key to exit"
}

# SIG # Begin signature block
# MIIbwgYJKoZIhvcNAQcCoIIbszCCG68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCChfSyhXhSk1wB/
# epWLkWOOKxRMi8d7fA1thdDwJ2nJHaCCFhMwggMGMIIB7qADAgECAhBpwTVxWsr9
# sEdtdKBCF5GpMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNVBAMMEEFUQSBBdXRoZW50
# aWNvZGUwHhcNMjMwNTIxMTQ1MjUxWhcNMjQwNTIxMTUxMjUxWjAbMRkwFwYDVQQD
# DBBBVEEgQXV0aGVudGljb2RlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
# AQEAoYBnOJ64OauwmbLN3bJ4EijORLohvNN3Qbjxxo/mTvQqqOLNAezk/A08LVg0
# GjQBR7L6LK/gnIVyeQxW4rKiLyJrS+3sBb+H6rTby5jiVBJmjiULxiVDEB+Fyz4h
# JGCWrn0BGGH4aLYfSdtlOD1sc0ySQuEuixZMV9dZIckNxYmJoeeLrwvnfio34ngy
# qxRY6lzULq9oTYoRTFSNxpb13mfZLhxz2pOzbEKBmYkbrDj4JtSzwBggly04oJXM
# ZZSRNavH6ZHxOUhs1UMgFHBe8dpepTBHY2uFjcynJaA5K02Yf2JAzfwc7A/tyuAM
# XNpK11pZ8aurlGws0W3TJtA6VQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYD
# VR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFIrvKx60YqR0ov787AjXn8zIl/36
# MA0GCSqGSIb3DQEBCwUAA4IBAQCdF+EBLn7mIQdZlfOFrJyarvy8SIaWcPUPVZPW
# ZdOH3U/HeANjbhPIZIbrmlB/uSqfoCOjKcqP1/wT1uHA8HdDkMC+WmWT0PpVBtr8
# W/dxgGc531Ykli1qn7qh8pKqQvSBC42cn3iX9KuN8yguyUIoxyATBBnJb/9a+nMA
# 3u8W3tF7gVwvvCETEE0cM8R6LY5/DjT5NRmo090lx/w8io//t0ZjyHuf9sY0CxLP
# 56MZgI/EIZq/M+LIX4WsYTvp3vkmcFDfhgEV8BVqKzPT/sKjKq61PED2jCjLj7L5
# Fdo8ip3XaTURhXg1syUHbSYOnCinoiT4AHIYJYrx+flT+9ecMIIFjTCCBHWgAwIB
# AgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQGEwJV
# UzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQu
# Y29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIw
# ODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UE
# ChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYD
# VQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Y
# q3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lX
# FllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxe
# TsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbu
# yntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I
# 9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmg
# Z92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse
# 5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKy
# Ebe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwh
# HbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/
# Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwID
# AQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM
# 3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDgYD
# VR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDov
# L29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+
# MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3Vy
# ZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUA
# A4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSI
# d229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096wwepqLsl7U
# z9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxA
# GTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAID
# yyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW
# /VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGrjCCBJagAwIBAgIQBzY3tyRUfNhHrP0o
# ZipeWzANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGln
# aUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhE
# aWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjIwMzIzMDAwMDAwWhcNMzcwMzIy
# MjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4x
# OzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGlt
# ZVN0YW1waW5nIENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAxoY1
# BkmzwT1ySVFVxyUDxPKRN6mXUaHW0oPRnkyibaCwzIP5WvYRoUQVQl+kiPNo+n3z
# nIkLf50fng8zH1ATCyZzlm34V6gCff1DtITaEfFzsbPuK4CEiiIY3+vaPcQXf6sZ
# Kz5C3GeO6lE98NZW1OcoLevTsbV15x8GZY2UKdPZ7Gnf2ZCHRgB720RBidx8ald6
# 8Dd5n12sy+iEZLRS8nZH92GDGd1ftFQLIWhuNyG7QKxfst5Kfc71ORJn7w6lY2zk
# psUdzTYNXNXmG6jBZHRAp8ByxbpOH7G1WE15/tePc5OsLDnipUjW8LAxE6lXKZYn
# LvWHpo9OdhVVJnCYJn+gGkcgQ+NDY4B7dW4nJZCYOjgRs/b2nuY7W+yB3iIU2YIq
# x5K/oN7jPqJz+ucfWmyU8lKVEStYdEAoq3NDzt9KoRxrOMUp88qqlnNCaJ+2RrOd
# OqPVA+C/8KI8ykLcGEh/FDTP0kyr75s9/g64ZCr6dSgkQe1CvwWcZklSUPRR8zZJ
# TYsg0ixXNXkrqPNFYLwjjVj33GHek/45wPmyMKVM1+mYSlg+0wOI/rOP015LdhJR
# k8mMDDtbiiKowSYI+RQQEgN9XyO7ZONj4KbhPvbCdLI/Hgl27KtdRnXiYKNYCQEo
# AA6EVO7O6V3IXjASvUaetdN2udIOa5kM0jO0zbECAwEAAaOCAV0wggFZMBIGA1Ud
# EwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFLoW2W1NhS9zKXaaL3WMaiCPnshvMB8G
# A1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjAT
# BgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGG
# GGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2Nh
# Y2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYD
# VR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQB9WY7Ak7ZvmKlEIgF+ZtbYIULhsBguEE0T
# zzBTzr8Y+8dQXeJLKftwig2qKWn8acHPHQfpPmDI2AvlXFvXbYf6hCAlNDFnzbYS
# lm/EUExiHQwIgqgWvalWzxVzjQEiJc6VaT9Hd/tydBTX/6tPiix6q4XNQ1/tYLaq
# T5Fmniye4Iqs5f2MvGQmh2ySvZ180HAKfO+ovHVPulr3qRCyXen/KFSJ8NWKcXZl
# 2szwcqMj+sAngkSumScbqyQeJsG33irr9p6xeZmBo1aGqwpFyd/EjaDnmPv7pp1y
# r8THwcFqcdnGE4AJxLafzYeHJLtPo0m5d2aR8XKc6UsCUqc3fpNTrDsdCEkPlM05
# et3/JWOZJyw9P2un8WbDQc1PtkCbISFA0LcTJM3cHXg65J6t5TRxktcma+Q4c6um
# AU+9Pzt4rUyt+8SVe+0KXzM5h0F4ejjpnOHdI/0dKNPH+ejxmF/7K9h+8kaddSwe
# Jywm228Vex4Ziza4k9Tm8heZWcpw8De/mADfIBZPJ/tgZxahZrrdVcA6KYawmKAr
# 7ZVBtzrVFZgxtGIJDwq9gdkT/r+k0fNX2bwE+oLeMt8EifAAzV3C+dAjfwAL5HYC
# JtnwZXZCpimHCUcr5n8apIUP/JiW9lVUKx+A+sDyDivl1vupL0QVSucTDh3bNzga
# oSv27dZ8/DCCBsIwggSqoAMCAQICEAVEr/OUnQg5pr/bP1/lYRYwDQYJKoZIhvcN
# AQELBQAwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTsw
# OQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVT
# dGFtcGluZyBDQTAeFw0yMzA3MTQwMDAwMDBaFw0zNDEwMTMyMzU5NTlaMEgxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjEgMB4GA1UEAxMXRGln
# aUNlcnQgVGltZXN0YW1wIDIwMjMwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQCjU0WHHYOOW6w+VLMj4M+f1+XS512hDgncL0ijl3o7Kpxn3GIVWMGpkxGn
# zaqyat0QKYoeYmNp01icNXG/OpfrlFCPHCDqx5o7L5Zm42nnaf5bw9YrIBzBl5S0
# pVCB8s/LB6YwaMqDQtr8fwkklKSCGtpqutg7yl3eGRiF+0XqDWFsnf5xXsQGmjzw
# xS55DxtmUuPI1j5f2kPThPXQx/ZILV5FdZZ1/t0QoRuDwbjmUpW1R9d4KTlr4HhZ
# l+NEK0rVlc7vCBfqgmRN/yPjyobutKQhZHDr1eWg2mOzLukF7qr2JPUdvJscsrdf
# 3/Dudn0xmWVHVZ1KJC+sK5e+n+T9e3M+Mu5SNPvUu+vUoCw0m+PebmQZBzcBkQ8c
# tVHNqkxmg4hoYru8QRt4GW3k2Q/gWEH72LEs4VGvtK0VBhTqYggT02kefGRNnQ/f
# ztFejKqrUBXJs8q818Q7aESjpTtC/XN97t0K/3k0EH6mXApYTAA+hWl1x4Nk1nXN
# jxJ2VqUk+tfEayG66B80mC866msBsPf7Kobse1I4qZgJoXGybHGvPrhvltXhEBP+
# YUcKjP7wtsfVx95sJPC/QoLKoHE9nJKTBLRpcCcNT7e1NtHJXwikcKPsCvERLmTg
# yyIryvEoEyFJUX4GZtM7vvrrkTjYUQfKlLfiUKHzOtOKg8tAewIDAQABo4IBizCC
# AYcwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMB8GA1Ud
# IwQYMBaAFLoW2W1NhS9zKXaaL3WMaiCPnshvMB0GA1UdDgQWBBSltu8T5+/N0GSh
# 1VapZTGj3tXjSTBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5n
# Q0EuY3JsMIGQBggrBgEFBQcBAQSBgzCBgDAkBggrBgEFBQcwAYYYaHR0cDovL29j
# c3AuZGlnaWNlcnQuY29tMFgGCCsGAQUFBzAChkxodHRwOi8vY2FjZXJ0cy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGltZVN0YW1w
# aW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCBGtbeoKm1mBe8cI1PijxonNgl
# /8ss5M3qXSKS7IwiAqm4z4Co2efjxe0mgopxLxjdTrbebNfhYJwr7e09SI64a7p8
# Xb3CYTdoSXej65CqEtcnhfOOHpLawkA4n13IoC4leCWdKgV6hCmYtld5j9smViuw
# 86e9NwzYmHZPVrlSwradOKmB521BXIxp0bkrxMZ7z5z6eOKTGnaiaXXTUOREEr4g
# DZ6pRND45Ul3CFohxbTPmJUaVLq5vMFpGbrPFvKDNzRusEEm3d5al08zjdSNd311
# RaGlWCZqA0Xe2VC1UIyvVr1MxeFGxSjTredDAHDezJieGYkD6tSRN+9NUvPJYCHE
# Vkft2hFLjDLDiOZY4rbbPvlfsELWj+MXkdGqwFXjhr+sJyxB0JozSqg21Llyln6X
# eThIX8rC3D0y33XWNmdaifj2p8flTzU8AL2+nCpseQHc2kTmOt44OwdeOVj0fHMx
# VaCAEcsUDH6uvP6k63llqmjWIso765qCNVcoFstp8jKastLYOrixRoZruhf9xHds
# FWyuq69zOuhJRrfVf8y2OMDY7Bz1tqG4QyzfTkx9HmhwwHcK1ALgXGC7KP845VJa
# 1qwXIiNO9OzTF/tQa/8Hdx9xl0RBybhG02wyfFgvZ0dl5Rtztpn5aywGRu9BHvDw
# X+Db2a2QgESvgBBBijGCBQUwggUBAgEBMC8wGzEZMBcGA1UEAwwQQVRBIEF1dGhl
# bnRpY29kZQIQacE1cVrK/bBHbXSgQheRqTANBglghkgBZQMEAgEFAKCBhDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAR
# yE/6a1dONquk6PuWoUJpeEPKSnTHIx9nGdAc+/OTczANBgkqhkiG9w0BAQEFAASC
# AQAY7KMsZO9x62BQ8w8Tl3aYhp+e13LcxzrJgJ1GF0+MkskxyEjRoSTQSafoT9El
# 8ba4kVj7czhtOhAgLf7uKjHj7ZAQErWGXsCkHWF4ZXhgCXdotzmSKD6FEWrqWrwJ
# 5kWuNIIz2FUumTOVyRPAR+F45RDve2yEP/GDHYqbTHLHqeuOTm+gQm79BCtaaQyO
# mN5LZFvsji79WyWdCAm8Lxkr0npUUkPUpWR7KEbNHH2y3+sW+BksqPMN1hAV41x5
# of0W4di8k3T3Q2bUqaJxZZoGi6t6U7k7ojOPwhAa7l4sEW4s6Z4USdXHf98/3BlS
# CtazXHR1xfilA74vUPxJtbFloYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEB
# MHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYD
# VQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFt
# cGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQMEAgEFAKBpMBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MDUxNTE5MTg0
# NlowLwYJKoZIhvcNAQkEMSIEIDVoADMyHxm1861oQp04MZ9sEbarAmxCetw3FZ9e
# tiYWMA0GCSqGSIb3DQEBAQUABIICACsUbAaDG10AFYPnMPSEQdSHxkxG1ZN1uypb
# 5qUyymsseu5aqMO2ednJFAud81NQ0Xu5hpteh1pATQ+mIWDebbZCGhrKZ+CC8T7Y
# k3x+521+5tI3csr5fbWrwPbiWvTw3mET+1B7hY1wqqEbQMIvL6tFq87Us3+9TKgL
# n405PqXJ3LzFCQuw+c6GfVSQe3BwcmudfZRe2NwLiMhdrCv1sasW8843RAPym2/Y
# OtY8t+go17CZBZfopW8HpFpYYAPLKvJGZiMOghAiWoiZXuAL7zxH2gui2U9nlwRc
# 2wefYJZi+CrFeSP95DwiWUUO3A8gWnWhzAmmrnwf6zycBou6qWwIs2zDP9ql0Asn
# gxb33ilz+6/Q7We9xDDAoG2Waln25ZHEu0azzDUlMwbzjks7QLtnj1TXo9TRLBhy
# HuBcfI6wP26FmPin2bqXjtQauXyyhbHGT8XBulNaYqoMElr5XdEXsbWabbyj3iBQ
# qVWiEe6n3XcRkOjybxVqloqjxWUVaPAGDWJAjA8evidfd47H+VmXaFCsWo1i/AU9
# wrkL2LAlOhzKJ0Un8CABZiDhxBvktnZyO3eEJQuuJtyIsETk2Wc7m0ME6H8E+hof
# vQ5RR8Xf8V2+FZyjnxdPs8g6xRA0dRD2WRVLPTiZ1G7gPLkOS5mIuM8ZFmvYgL4T
# 4CzgdHxS
# SIG # End signature block
