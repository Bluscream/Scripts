# Start All Non-Disabled Services
# Simple script to start every service that is not disabled

Write-Host "Starting all non-disabled services..." -ForegroundColor Green

# Get all services that are not disabled and not already running
$services = Get-Service | Where-Object { $_.StartType -ne 'Disabled' -and $_.Status -ne 'Running' }

Write-Host "Found $($services.Count) services to start" -ForegroundColor Yellow

foreach ($service in $services) {
    try {
        Write-Host "Starting $($service.Name)..." -ForegroundColor Cyan
        Start-Service -Name $service.Name -ErrorAction Stop
        Write-Host "✓ Started $($service.Name)" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Failed to start $($service.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "Completed starting services." -ForegroundColor Green
