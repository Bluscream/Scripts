param (
    [switch]$skipUAC = $false
)

Function GetKeyPress([string]$regexPattern = '[ynq]', [string]$message = $null, [int]$timeOutSeconds = 0) {
    $key = $null
    $Host.UI.RawUI.FlushInputBuffer() 
    if (![string]::IsNullOrEmpty($message)) {
        Write-Host -NoNewLine $message
    }
    $counter = $timeOutSeconds * 1000 / 250
    while ($null -eq $key -and ($timeOutSeconds -eq 0 -or $counter-- -gt 0)) {
        if (($timeOutSeconds -eq 0) -or $Host.UI.RawUI.KeyAvailable) {                       
            $key_ = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown,IncludeKeyUp")
            if ($key_.KeyDown -and $key_.Character -match $regexPattern) {
                $key = $key_                    
            }
        } else {
            Start-Sleep -m 250
        }
    }                       
    if (-not ($null -eq $key)) {
        Write-Host -NoNewLine "$($key.Character)" 
    }
    if (![string]::IsNullOrEmpty($message)) {
        Write-Host ""
    }       
    return $(if ($null -eq $key) { $null } else { $key.Character })
}
function Update-Pip {
    # Get a list of all installed packages
    $installedPackages = & pip list --format=freeze

    # Iterate over each package and upgrade it
    foreach ($package in $installedPackages) {
        # Extract the package name from the line
        $packageName = $package.Split("==")[0]

        # Upgrade the package
        & pip install --upgrade $packageName
    }
}
function Update-Npm {
    # Get list of outdated packages
    $outdatedPackages = & npm outdated --json | ConvertFrom-Json

    foreach ($package in $outdatedPackages.data) {
        # Update each package individually
        & npm install $($package.name)@latest
    }
}


if (-Not $skipUAC) {
    if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
            $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
            Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine
            Exit
        }
    }
}
$Host.UI.RawUI.WindowTitle = 'Updating scoop'
scoop install git
scoop update * -g
$Host.UI.RawUI.WindowTitle = 'Updating chocolatey'
choco upgrade all --accept-license --yes --allowunofficial --install-if-not-installed --ignorechecksum
$cmd = "winget upgrade --all --accept-package-agreements --accept-source-agreements"
if ((GetKeyPress -regexPattern '[yn]' -message "Skip `"winget upgrade --all`"? (y/[n])" -timeOutSeconds 10) -ne "y") {
    if ((GetKeyPress -regexPattern '[yn]' -message "Skip unknown package versions? (y/[n])" -timeOutSeconds 5) -ne "y") {
        $cmd += " --include-unknown"
    } else {
        Write-Output "Only updating known package versions..."
    }
    Write-Output "Running $cmd"
    $Host.UI.RawUI.WindowTitle = 'Updating winget'
    Invoke-Expression $cmd
} else {
    Write-Output "Skipping winget..."
}
$Host.UI.RawUI.WindowTitle = 'Updating pip'
Update-Pip
$Host.UI.RawUI.WindowTitle = 'Updating npm'
Update-Npm
$Host.UI.RawUI.WindowTitle = 'Updating windows'
Install-Module PSWindowsUpdate -force
Import-Module PSWindowsUpdate
Get-WindowsUpdate
Add-WUServiceManager -MicrosoftUpdate -Confirm:$false # -ServiceID "7971f918-a847-4430-9279-4a52d1efe18d"
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll
Function pause ($message) {
    if ($psISE) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$message")
    } else {
        Write-Host "$message" -ForegroundColor Yellow
        $x = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}
pause "Press any key to exit"
# SIG # Begin signature block
# MIIbwgYJKoZIhvcNAQcCoIIbszCCG68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBZksUv0+t4h6eD
# cZf4ySpUoyyE1YbL+aVJ1n975vfRu6CCFhMwggMGMIIB7qADAgECAhBpwTVxWsr9
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCS
# IW0KeMesfzLKO70ka8CM64AAJxQTfognsXoaiM784DANBgkqhkiG9w0BAQEFAASC
# AQAwj/GSWlWvi02xPnawSHFf9yPXAOfifMNKP6qgXhIpHipmrXUPuLQoUY3jkLuq
# oEZjJ7TL0se/suOOS8Lsiv5uh4mPbK7oGIFC4OWdqi9LUWIKJ9RlK1ErgvL8jjMe
# r4HcNoNTdMSp9yEBWqyq9AH6JnR9SA4TXu/6J2IZxGqfRNHmPnIdntqpyOuS+R1t
# quOeKGckPnXv0iVJrP7zwZ/K1pR+gmaXR3GjZ83h5EiV1DQSqSWCM6KPUtcEsnZj
# 9B0DaESZ9QAJJQNd4tbDGExkKfGgHTABLgrMAu+sqWWLfC9Brb22lMQWOUA1QSqu
# kcUS4g7bBuQqGiBuAST9XZuRoYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEB
# MHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYD
# VQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFt
# cGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQMEAgEFAKBpMBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MDIxOTA5MjU0
# NVowLwYJKoZIhvcNAQkEMSIEIIDclQC43B38Nqv/Kr+wRNSSTwuuHYt0GK3lKBTn
# mphRMA0GCSqGSIb3DQEBAQUABIICAEJkJKMRD16mXOg2HqlTbmIK4epBAf44Btof
# IMihoDAkprPM5xKWtlGbjBhAyS6GcTh1IxsVeyhCKJ/ic6gNmwaPjxhdWnHDimVx
# 81VACK3sq4Nq+qcXSikXCBV+gUy69Wz66IsiXl0JuYKw0LrcijBzZW+I/2yniTe5
# wwD5TkDelqO41FlgSfxbQ24ZyV8Q08R48dN8OV5AvFV/AUoOSTfadXlUARa0/4lt
# FuGJ+glwGjZXoEJYo9Bq08DlVR/pr81JkABipje97ojRb5YyH5sJQ9ZNDtGwcm9i
# eo/4V9F/5KkcqfRJ0mDF2WUw7WZOkKsycuiUoHMZKHQGKT6/7b/q4A2HLoEpkwUq
# bAlJALI0zKfS8rkFUwFDlUWUduXaeybcu+oJyf43ySuonHhIFWjRoBNdoSDaPGkg
# CV8V6R2oRUJ+67MrBMC1BXgZ4AIQfwbI7mrs61/vkyHYV7wzT9jjK6QssESG0i9P
# lfTF4y7+OmOHrKLjYXvVD0b5tD+dapaKQToIIHj2D8jxCAcQ7E+DeW9ssU33XJpY
# Jo2t/4s8NO9wfyPUNj5CblF82u4lUHHzUg8gitfcesaP4whitzACM7y8SQvIDC2d
# nV+msCE1Egq7qq9f0eoHmrJoIL0QvP1VY7Zg0UF1/ONcPlgMepHW9b0Wt55Stl6h
# l4WDUuHE
# SIG # End signature block
