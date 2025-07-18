param (
    [switch]$pip,
    [switch]$npm,
    [switch]$windows,
    [switch]$eventlogs,
    [switch]$all,
    [switch]$default,
    [switch]$skipUAC = $false,
    [switch]$help
)

$allByDefault = $false # Can set to true to update everything by default instead of showing help

function Print-Help {
    Write-Host @"
Usage: ./update.ps1 [options]
Options:
    -pip                : Uninstall all unimportant pip packages
    -npm                : Uninstall all unimportant npm packages
    -windows            : Clean Windows (Disk Cleanup, Temp, Prefetch, Update cache)
    -eventlogs          : Clear Windows event logs
    -all                : Uninstall all unimportant packages
    -default            : Uninstall all unimportant (pip, npm) packages
    -skipUAC            : Skip User Account Control prompt
    -help               : Display this help message
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

function Backup-Pip {
    Set-Title "Backing up pip packages"
    # Get a list of all installed pip packages with their versions
    $pipList = pip list --format=freeze

    # Specify the backup file path
    $backupFilePath = "requirements.txt"

    # Create the backup file
    $pipList | Out-File -FilePath $backupFilePath -Encoding utf8

    Write-Host "Pip packages have been backed up to $backupFilePath"
}
function Clear-Pip {
    # List of essential pip packages that should not be uninstalled
    $essentialPackages = "wheel", "setuptools", "pip"

    Set-Title "Cleaning pip packages except ($essentialPackages)"

    # Get a list of all installed pip packages
    $allPackages = pip list --format=freeze | ForEach-Object { $_.Split('==')[0] }

    # Filter out the essential packages
    $unimportantPackages = $allPackages | Where-Object { $_ -notin $essentialPackages }

    # Uninstall the unimportant packages
    foreach ($package in $unimportantPackages) {
        pip uninstall -y $package
    }
}

function Backup-Npm {
    Set-Title "Backing up npm packages"
    # Check if the npm directory exists
    $npmDir = "$env:APPDATA\npm"
    if (-not (Test-Path $npmDir)) {
        Write-Error "Npm directory not found: $npmDir"
        return
    }
    
    # Get a list of all installed npm packages with their versions
    $npmList = npm list --global --json | ConvertFrom-Json
    
    # Check if the npmList object has a dependencies property
    if ($null -eq $npmList.dependencies) {
        Write-Error "No dependencies found in npm list output"
        return
    }
    
    # Convert the package list to JSON format
    $npmListJson = $npmList.dependencies | ConvertTo-Json
    
    # Specify the backup file path
    $backupFilePath = "packages.json"
    
    # Create the backup file
    $npmListJson | Out-File -FilePath $backupFilePath -Encoding utf8
    
    Write-Host "Npm packages have been backed up to $backupFilePath"
}
function Clear-Npm {
    # List of essential npm packages that should not be uninstalled
    $essentialPackages = "npm"

    Set-Title "Cleaning npm packages except ($essentialPackages)"

    # Get a list of all installed npm packages
    $allPackages = npm list --depth=0 --global --json | ConvertFrom-Json | ForEach-Object { $_.dependencies | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name } }

    # Filter out the essential packages
    $unimportantPackages = $allPackages | Where-Object { $_ -notin $essentialPackages }

    # Uninstall the unimportant packages
    foreach ($package in $unimportantPackages) {
        npm uninstall -g $package
    }
}

function Clear-Windows {
    Set-Title "Cleaning Windows"

    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*' | % {
        New-ItemProperty -Path $_.PSPath -Name StateFlags0001 -Value 2 -PropertyType DWord -Force
    };
    Start-Process -FilePath CleanMgr.exe -ArgumentList '/sagerun:1' # -WindowStyle Hidden
    # Get-Process -Name cleanmgr,dismhost -ErrorAction SilentlyContinue | Wait-Process

    $users = Get-ChildItem -Path $env:SystemDrive\Users -Directory
    foreach ($user in $users) {
        $tempDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Temp'
        Set-Title "Cleaning Windows ($tempDir)"
        Remove-Item -Path $tempDir\* -Recurse -Force
        # Clear CrashDumps folder for all users
        $crashDumpsDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\CrashDumps'
        if (Test-Path $crashDumpsDir) {
            Set-Title "Cleaning CrashDumps ($crashDumpsDir)"
            Remove-Item -Path "$crashDumpsDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Clear NVIDIA cache folders for all users
        $nvidiaCacheFolders = @("DXCache", "GLCache", "OptixCache")
        foreach ($cacheFolder in $nvidiaCacheFolders) {
            $nvidiaPath = Join-Path -Path $user.FullName -ChildPath "AppData\Local\NVIDIA\$cacheFolder"
            if (Test-Path $nvidiaPath) {
                Set-Title "Cleaning NVIDIA $cacheFolder ($nvidiaPath)"
                Remove-Item -Path "$nvidiaPath\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        # Clear INetCache and WebCache folders for all users
        $inetCacheDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Microsoft\Windows\INetCache'
        if (Test-Path $inetCacheDir) {
            Set-Title "Cleaning INetCache ($inetCacheDir)"
            Remove-Item -Path "$inetCacheDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        $webCacheDir = Join-Path -Path $user.FullName -ChildPath 'AppData\Local\Microsoft\Windows\WebCache'
        if (Test-Path $webCacheDir) {
            Set-Title "Cleaning WebCache ($webCacheDir)"
            Remove-Item -Path "$webCacheDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Set-Title "Cleaning Windows ($env:windir\Temp)"
    Remove-Item -Path $env:windir\Temp\* -Recurse -Force

    Set-Title "Cleaning Windows prefetch"
    Remove-Item -Path $env:windir\Prefetch\* -Recurse -Force

    Set-Title "Cleaning Windows memory dump"
    Remove-Item -Path $env:windir\memory.dmp -Force

    Set-Title "Cleaning Windows Update cache"
    net stop wuauserv
    Remove-Item -Path $env:windir\SoftwareDistribution\* -Recurse -Force
    net start wuauserv
}
function Clear-WindowsEventlogs {
    Set-Title "Cleaning Windows event logs"
    $LogNames = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LogName
    Write-Host "Found $($LogNames.Count) event logs"

    foreach ($LogName in $LogNames) {
        $txt = "Clearing $LogName"
        $logSizeMB = -1
        try {
            $fistLogEvent = Get-WinEvent -LogName $LogName -MaxEvents 1 --ErrorAction SilentlyContinue
            $logSizeMB = $fistLogEvent.MaximumSizeInBytes / 1MB
            $txt += " ($logSizeMB MB)"
        } catch { }
        Write-Host $txt
        try {
            wevtutil.exe cl "$LogName"
        } catch {
            Write-Host "Failed to clear $LogName. Error: $_"
        }
    }
}

if ($allByDefault -and $MyInvocation.BoundParameters.Count -eq 0) {
    $pip = $true
    $npm = $true
    $windows = $true
    $eventlogs = $true
}
elseif ($help -or $MyInvocation.BoundParameters.Count -eq 0) {
    Print-Help
    exit
}

if (-Not $skipUAC) { Elevate-Script }
if ($all -or $default -or $npm) {
    Backup-Npm
    Clear-Npm
}
if ($all -or $default -or $pip) {
    Backup-Pip
    Clear-Pip
}
if ($all -or $default -or $windows) {
    Clear-Windows
}
if ($all -or $default -or $eventlogs) {
    Clear-WindowsEventlogs
}

if ($PauseBeforeExit) {
    pause "Press any key to exit"
}

# SIG # Begin signature block
# MIIbwgYJKoZIhvcNAQcCoIIbszCCG68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAN7RYTcB2RESFS
# F3Gw49wBxPXR3n5wtKaMdg95rrc7J6CCFhMwggMGMIIB7qADAgECAhBpwTVxWsr9
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBS
# ncW9thI9vAbDUuyCXHTiNZAGUS10LKgtCY5mc7nHITANBgkqhkiG9w0BAQEFAASC
# AQAzVtP+nq1kZlHZv2Yl8FqpVJjeBg+v3P+Y6uXq0irVdBlvimPvD0Us+uT3pX8D
# pl3dYG+t8Qu2YOY0dI9sS9oX461kN6Ma9a0hL8DaU/l19sfS/l38Ad3EB20oCJaX
# ObtAWXRORLxoSFtU26B5UGwVTT7Wpp+1+yazNs2HU5CZ+0gq4Pgvlzm9Z+5M0RuR
# E24y8ay6yQ2XNH4xHXWyY8tTHx3xHIe5bxky+/jnN7qLZW5vmgN5f0yx+83n/RBy
# L5obONYxTsthErLJcouTtoT8QJ1uogrC4MhMQm5sD9wb38ijHQmSLbORUCR7o6tX
# 4x40mQQrZa9EGvt57GvMNJ8NoYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEB
# MHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYD
# VQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFt
# cGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQMEAgEFAKBpMBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MDUxNTE5MTgz
# N1owLwYJKoZIhvcNAQkEMSIEIMCOODR0feupInmH8mIB8fnZDxROGdYIOkisspmq
# 7XZFMA0GCSqGSIb3DQEBAQUABIICADIjlcfpzfxTCCUCdSrIIM+cfanP176x/p/S
# yd24V0LwU5L+1yzFjk2WuA8oDHShWenOYq50th59p1PDoXAZj9AyyFAbVuUtU67i
# qCH480o94AtC105dkvY4y87n2NXhVhU1sbLhsShCG5gFxACEznjIjTvqmX7nKxYd
# REpA/aVGQAkEhMDW9rPLvv8a8wPfxHbMHtUr4SlfYztTjI7oCm6/gyUcSs7bIXlV
# htuzah6dkWsdzghFdzwBKmYJ2bfRoanQiqrwvYPsKW6EHV32Uh3fvPKjMpdYkjEx
# BcpPxDFFKfGjMbup/qU9eZKLBfM+7rcjcwhRLI0QrR8LsgKZIKTU4+TW/tjEobXN
# /AFxSEJHMwP9MY8wg9e1ryCmRayaQezO9hiyG0FvUAh++sYHN7qKfNuZKaWxdOg/
# GbrcMTz3IYsjajViArfWtM7tem3/RkcNIgY+he1iUL0E/6y2+MYMMv890O2uHoB0
# 4SZrhW5+OPqy92gpf6gSXOA6wx037NelBkAPUPhE9JcgGp8X7ccE6u+GIsEJBnQk
# bZ882pB9+apq8irhdnEPL0nfnO1hkbuKXuk9gTIcLm88cpEvI5tta8+LTcyOJt8I
# lslmvNik3JUXVSHObDXCSG2UctMcN2byGBCTLl45rRvfVT/LNUZOVHAdpSVtm6yv
# jwUDPiIe
# SIG # End signature block
