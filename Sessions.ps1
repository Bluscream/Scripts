function Get-Sessions {
    param (
        [string]$ComputerName = $env:COMPUTERNAME
    )

    # --- WMI Sessions ---
    $sessions = Get-WmiObject -Class Win32_LogonSession -ComputerName $ComputerName
    $userSessions = @()

    foreach ($session in $sessions) {
        $assoc = Get-WmiObject -Query "Associators of {Win32_LogonSession.LogonId=$($session.LogonId)} Where AssocClass=Win32_LoggedOnUser" -ComputerName $ComputerName
        foreach ($user in $assoc) {
            if ($user.Antecedent) {
                $userPath = $user.Antecedent.ToString()
                $userName = $null
                $userDomain = $null
                if ($userPath -match 'Win32_UserAccount.Domain=\"([^\"]+)\",Name=\"([^\"]+)\"') {
                    $userDomain = $matches[1]
                    $userName = $matches[2]
                }
                if ($userName) {
                    $userSessions += [PSCustomObject]@{
                        Source     = 'WMI'
                        UserName   = $userName
                        Domain     = $userDomain
                        LogonId    = $session.LogonId
                        LogonType  = $session.LogonType
                        StartTime  = $session.StartTime
                    }
                }
            }
        }
    }

    # --- QUSER & QUERY USER ---
    $quserOutput = try { quser /server:$ComputerName 2>$null } catch { @() }
    $queryUserOutput = try { query user /server:$ComputerName 2>$null } catch { @() }

    function Parse-SessionOutput {
        param($lines, $source)
        $parsed = @()
        if ($lines -and $lines.Count -gt 1) {
            # $header = $lines[0]
            $data = $lines[1..($lines.Count-1)]
            foreach ($line in $data) {
                $line = $line.Trim()
                if ($line) {
                    $parts = $line -split '\s{2,}'
                    if ($parts.Count -ge 6) {
                        $parsed += [PSCustomObject]@{
                            Source    = $source
                            UserName  = $parts[0]
                            Session   = $parts[1]
                            Id        = $parts[2]
                            State     = $parts[3]
                            IdleTime  = $parts[4]
                            LogonTime = $parts[5]
                        }
                    }
                }
            }
        }
        return $parsed
    }

    $quserSessions = Parse-SessionOutput $quserOutput 'QUSER'
    $queryUserSessions = Parse-SessionOutput $queryUserOutput 'QUERY_USER'

    # Merge sessions by Session Id or UserName
    $merged = @{}
    foreach ($s in $userSessions + $quserSessions + $queryUserSessions) {
        $key = if ($s.Id) { $s.Id } elseif ($s.LogonId) { $s.LogonId } elseif ($s.UserName) { $s.UserName } else { [guid]::NewGuid().ToString() }
        if (-not $merged.ContainsKey($key)) {
            $merged[$key] = @{}
        }
        foreach ($prop in $s.PSObject.Properties) {
            if (-not $merged[$key].ContainsKey($prop.Name) -or !$merged[$key][$prop.Name]) {
                $merged[$key][$prop.Name] = $prop.Value
            }
        }
    }

    # Return merged sessions as objects
    return $merged.Values | Select-Object UserName,Domain,Session,Id,LogonId,LogonType,State,IdleTime,StartTime,LogonTime,Source
}

$result = Get-Sessions
Write-Host $result | Format-Table -AutoSize