param(
    [string]$ip,
    [string]$user,
    [string]$pw,
    [string]$cmd # "tail -f /var/log/"
)


function run {
    # param ($cmd)
    $session = New-SshSession -ComputerName $ip -Credential $credential
    Invoke-SshCommand -SessionId $session.SessionId -Command "uname -a;whoami"
    Invoke-SshCommandStream -SessionId $session.SessionId -Command "ls /var/log/"
    Invoke-SshCommandStream -SessionId $session.SessionId -Command $cmd -EnsureConnection
    Remove-SshSession -SessionId $session.SessionId
    run
}

if (-not (Get-Command New-SshSession -ErrorAction SilentlyContinue)) {
    Install-Module -Name Posh-SSH -Force
    Import-Module Posh-SSH
}
if (-not (Get-Command New-StoredCredential -ErrorAction SilentlyContinue)) {
    Install-Module -Name CredentialManager -Force
    Import-Module CredentialManager
}

$target = "$($ip)_$($user)"
Write-Host "Target: $target"

# $credential = Get-StoredCredential -Target $target
# if (-not $credential) {
#     $credential = Get-Credential
#     New-StoredCredential -Target $target -UserName $credential.UserName -Password $credential.GetNetworkCredential().Password -Persist LocalMachine
# }
$credential = New-Object System.Management.Automation.PSCredential ($user, (ConvertTo-SecureString $pw -AsPlainText -Force))
run

Read-Host "Press any key to continue..."





