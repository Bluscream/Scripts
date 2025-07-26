# Toggle-DND.ps1
# Script to toggle Do Not Disturb mode on Windows 10/11

# Get current DND state
$regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
$regName = "NOC_GLOBAL_SETTING_TOASTS_ENABLED"

# Check if the registry key exists
if (-not (Test-Path $regPath)) {
    Write-Error "Do Not Disturb setting not found. This script works on Windows 10/11."
    exit 1
}

$current = Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue

if ($null -eq $current) {
    # If the value does not exist, default to enabled (1)
    $enabled = 1
} else {
    $enabled = $current.$regName
}

if ($enabled -eq 1) {
    # Currently notifications are enabled, so turn on DND (disable notifications)
    Set-ItemProperty -Path $regPath -Name $regName -Value 0
    Write-Host "Do Not Disturb mode ENABLED (notifications off)."
} else {
    # Currently notifications are disabled, so turn off DND (enable notifications)
    Set-ItemProperty -Path $regPath -Name $regName -Value 1
    Write-Host "Do Not Disturb mode DISABLED (notifications on)."
}
