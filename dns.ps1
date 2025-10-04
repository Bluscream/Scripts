$dnsservers = @{
  "hass"          = @(
    "192.168.2.4", "fe80::360a:cf28:dbb7:3bc9",
    "192.168.2.5", "fe80::a50f:919f:47b3:c4c1",
    "100.100.1.4", "fd7a:115c:a1e0::5c01:d661"
  );
  "nas"           = @(
    "192.168.2.10", "fe80::1e1b:dff:fe76:8bf3",
    "192.168.2.12",
    "100.100.1.10", "fd7a:115c:a1e0::401:1e62"
  );
  "homeserver"    = @(
    "192.168.2.38", "fd00::ba98:a7bb:ac07:57fd",
    "192.168.2.39", "fd00::505f:c63a:83df:2561"
  );
  "adguarddns"    = @(
    "94.140.14.14", "2a10:50c0::ad1:ff",
    "94.140.15.15", "2a10:50c0::ad2:ff"
  )
  "cloudflaredns" = @(
    "1.1.1.1", "2606:4700:4700::1111",
    "1.0.0.1", "2606:4700:4700::1001"
  )
}

$dns = $dnsservers["hass"] + $dnsservers["nas"] + $dnsservers["adguarddns"] + $dnsservers["cloudflaredns"]


Write-Host "DNS Servers:"
foreach ($server in $dns) {
  Write-Host " - $server"
}
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {  
  $arguments = "& '" + $myinvocation.mycommand.definition + "'"
  Start-Process powershell -Verb runAs -ArgumentList $arguments
  Break
}

try {
  $profiles = Get-NetConnectionProfile -ErrorAction Stop | Select-Object InterfaceAlias, InterfaceIndex
}
catch {
  Write-Host "Get-NetConnectionProfile is not available. Falling back to Get-NetAdapter."
  $profiles = Get-NetAdapter | Select-Object Name, InterfaceIndex
}

$whitelist = @() # @("2.5GB Ethernet")
$blacklist = @() # @("Powerline", "Wi-Fi")

foreach ($k in $profiles) {
  # Get-NetAdapter Get-DnsClientServerAddress
  [string]$devstr = "{0} ({1})" -f $k.InterfaceAlias, $k.InterfaceIndex
  $whitelisted = (-not $whitelist -or $whitelist.Count -eq 0) -or ($whitelist -contains $k.InterfaceAlias)
  $blacklisted = $k.InterfaceAlias -in $blacklist
  if ($whitelisted -and -not $blacklisted) {
    Write-Host "Changing DNS for $devstr"
    Set-DNSClientServerAddress -InterfaceIndex $k.InterfaceIndex -ServerAddresses $dns
  }
  else {
    Write-Host "Resetting DNS for $devstr"
    Set-DNSClientServerAddress -InterfaceIndex $k.InterfaceIndex -ResetServerAddresses
  }
}

ipconfig /flushdns

nslookup google.com
  
# $Nic1 = (Get-DnsClientServerAddress | where {}).InterfaceAlias
  
# Set-DNSClientServerAddress "InterfaceAlias" –ServerAddresses ("preferred-DNS-address", "alternate-DNS-address")
Pause
# SIG # Begin signature block
# MIIbwgYJKoZIhvcNAQcCoIIbszCCG68CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA2fh/yZPWoIsWe
# DbbTET3H6I7Bk8oKrCFmY/Gz3oskOqCCFhMwggMGMIIB7qADAgECAhBpwTVxWsr9
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
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBU
# 3gdZ19dxoVO6XTr1VL27o/ZpCNjVypADGdQxjWTqRDANBgkqhkiG9w0BAQEFAASC
# AQB24QhY+PCVHfv9SawAEqt6KLYojo6QMoi6e5GT2zRYCv15ST3Wr0cO+TmNQ7Az
# 4ZK/YFLPKJ6RK95Oqmf9jI/2wHOFwRhlHwZnQCbTuGPJig2wfgTpbWu1mrb2Aes6
# mVlXas+yguMhJgYxoId6uIx+lIKVb7Dsb8arz/LDzAY0HroxS0Wb9O162aH5ACWn
# 4CxiVVjnfuO8iE0Xk4gSz7oypif9XOmRqI3CEkwqL1/ovmoUjnOJa4mK+Pdy5ibp
# w5WDO7A185PVM8iFLoyIiK9+b+a7ezrIm+TcFKaKO/OMYxb/3+fOdReGyJw3ZF4+
# X5RJs++vPBRYGDUV6DAHm0KGoYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEB
# MHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYD
# VQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFt
# cGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgBZQMEAgEFAKBpMBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MDUxNTE5MTgz
# N1owLwYJKoZIhvcNAQkEMSIEIMQGS0P8O3zXqCHNfRod3TB0dxgu2zo6yrO1hdx4
# i2LmMA0GCSqGSIb3DQEBAQUABIICABm1Zv6aRZXmOldimg0paXfP5NaSx4DDtgV7
# UXDBledh2j+OQdpwf8sodxBgp5LywDGaVWCvLAn+awHOx5ZhlB+5NGfN1xYcm2FU
# IfOxiaINazn6tfeAJFhBQnEEesqwEgQhneCEJ+c0BTErdWpS8XD/63xMA7a0ZIkM
# yQ6wu9hsQAJRp8wQzIIGosqi9MKQ85l2YY+I8wPBG5Xjl7yS5F/gK/ovfH/1dkQ5
# NumrYrYlQWFnU/dmk4/4qxZepPjxfIgPDlLKNvTQkzFh8OfBikj5cPRp44NO2iVq
# tbr3dsJeUefBnGQT64pkyAoKKvayIcgYlwe4PgLkcmazFNJvE2ERHZgXVRooDl/Y
# Hh8c7qa6UqDL+R6+BwaROI/R6NsCBmOIi3dr9hpf9nOIjhCTxBp3+f4exsy2gzCe
# P+CPNgM4yosUCMTZwqCZuxae55FbWTjEWEolw2v58ckHGbNRJdH0bSqyf+OesSuY
# 06HavgOjk+33PDJP4Ae+WO2sP82pA6HvXWIwFFeLBeveve+W1Y9UsnjZ8BMDW7VA
# Fdz3ZT/104hwpQ4qaiIexU+6VHBoaTaqnS3uFicT1ZrTBS3qUpYOlZ4lfIXfW1nr
# w0IhSq07dqZwkabeKYGc38mONShwkaoQa3xK9YO5lM2M41l1P8H6kTn4JQyt5rzt
# SuSQfo+q
# SIG # End signature block
