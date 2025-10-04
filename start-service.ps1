param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceName
)

# Color functions for visual feedback
function Write-Success { param($Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✅ $Message" -ForegroundColor Green }
function Write-Error { param($Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✗ $Message" -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ⚠️ $Message" -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan }

# Function to get service dependencies recursively and return them in dependency order (bottom-up)
function Get-ServiceDependenciesInOrder {
    param(
        [string]$ServiceName,
        [hashtable]$Visited = @{},
        [array]$DependencyOrder = @()
    )
    
    if ($Visited.ContainsKey($ServiceName)) {
        return $DependencyOrder
    }
    
    $Visited[$ServiceName] = $true
    
    try {
        # Get dependencies using the ServiceController method
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        $serviceDeps = $service.ServicesDependedOn | Select-Object -ExpandProperty Name
        
        if ($serviceDeps) {
            foreach ($dep in $serviceDeps) {
                if ($dep -and $dep -ne $ServiceName) {
                    # Recursively get dependencies of this dependency first
                    $DependencyOrder = Get-ServiceDependenciesInOrder -ServiceName $dep -Visited $Visited -DependencyOrder $DependencyOrder
                    
                    # Add this dependency to the list if not already present
                    if ($DependencyOrder -notcontains $dep) {
                        $DependencyOrder += $dep
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve dependencies for service: $ServiceName"
    }
    
    return $DependencyOrder
}

# Function to start a service with retry logic
function Start-ServiceWithRetry {
    param(
        [string]$ServiceName,
        [int]$MaxRetries = 3,
        [int]$RetryDelay = 2
    )
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Info "Attempting to start service: $ServiceName (Attempt $i/$MaxRetries)"
            
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            
            if ($service.Status -eq 'Running') {
                Write-Success "Service '$ServiceName' is already running"
                return $true
            }
            
            Start-Service -Name $ServiceName -ErrorAction Stop
            Start-Sleep -Seconds 2
            
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($service.Status -eq 'Running') {
                Write-Success "Successfully started service: $ServiceName"
                return $true
            }
            else {
                Write-Warning "Service '$ServiceName' started but status is: $($service.Status)"
                return $false
            }
        }
        catch {
            Write-Error "Failed to start service '$ServiceName' (Attempt $i/$MaxRetries): $($_.Exception.Message)"
            
            if ($i -lt $MaxRetries) {
                Write-Info "Waiting $RetryDelay seconds before retry..."
                Start-Sleep -Seconds $RetryDelay
            }
        }
    }
    
    return $false
}

# Function to restart a service
function Restart-ServiceWithRetry {
    param(
        [string]$ServiceName,
        [int]$MaxRetries = 3,
        [int]$RetryDelay = 2
    )
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Info "Attempting to restart service: $ServiceName (Attempt $i/$MaxRetries)"
            
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            
            if ($service.Status -eq 'Running') {
                Write-Info "Stopping service: $ServiceName"
                Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                Start-Sleep -Seconds 3
            }
            
            Start-Service -Name $ServiceName -ErrorAction Stop
            Start-Sleep -Seconds 2
            
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($service.Status -eq 'Running') {
                Write-Success "Successfully restarted service: $ServiceName"
                return $true
            }
            else {
                Write-Warning "Service '$ServiceName' restarted but status is: $($service.Status)"
                return $false
            }
        }
        catch {
            Write-Error "Failed to restart service '$ServiceName' (Attempt $i/$MaxRetries): $($_.Exception.Message)"
            
            if ($i -lt $MaxRetries) {
                Write-Info "Waiting $RetryDelay seconds before retry..."
                Start-Sleep -Seconds $RetryDelay
            }
        }
    }
    
    return $false
}

# Main execution
Write-Info "=== Service Startup Script ==="
Write-Info "Target Service: $ServiceName"
Write-Info ""

# Check if the target service exists
try {
    $targetService = Get-Service -Name $ServiceName -ErrorAction Stop
    Write-Info "Target service found. Current status: $($targetService.Status)"
}
catch {
    Write-Error "Service '$ServiceName' not found!"
    exit 1
}

# Try to restart the target service first
Write-Info "=== Attempting to restart target service ==="
$targetStarted = Restart-ServiceWithRetry -ServiceName $ServiceName

if ($targetStarted) {
    Write-Success "Target service '$ServiceName' restarted successfully!"
    exit 0
}

Write-Warning "Failed to start target service. Attempting to start/restart dependencies..."

# Get dependencies in proper order (bottom-up)
$dependencies = Get-ServiceDependenciesInOrder -ServiceName $ServiceName
$failedServices = @()
$successfulServices = @()

if ($dependencies.Count -gt 0) {
    Write-Info "Found $($dependencies.Count) dependencies to process:"
    $dependencies | ForEach-Object { Write-Info "  - $_" }
    Write-Info ""
    
    foreach ($dep in $dependencies) {
        Write-Info "=== Processing dependency: $dep ==="
        
        try {
            # Always restart each dependency service
            $result = Restart-ServiceWithRetry -ServiceName $dep
            
            if ($result) {
                $successfulServices += $dep
            }
            else {
                $failedServices += $dep
            }
        }
        catch {
            Write-Error "Could not process dependency '$dep': $($_.Exception.Message)"
            $failedServices += $dep
        }
        
        Write-Info ""
    }
}
else {
    Write-Warning "No dependencies found for service '$ServiceName'"
}

# Try to restart the target service again after handling dependencies
Write-Info "=== Retrying target service after dependency processing ==="
$targetStarted = Restart-ServiceWithRetry -ServiceName $ServiceName

# Summary
Write-Info ""
Write-Info "=== SUMMARY ==="
Write-Info "Target Service: $ServiceName"

if ($targetStarted) {
    Write-Success "✓ Target service restarted successfully!"
}
else {
    Write-Error "✗ Target service failed to restart"
}

if ($successfulServices.Count -gt 0) {
    Write-Success "✓ Successfully processed dependencies ($($successfulServices.Count)):"
    $successfulServices | ForEach-Object { Write-Success "  - $_" }
}

if ($failedServices.Count -gt 0) {
    Write-Error "✗ Failed dependencies ($($failedServices.Count)):"
    $failedServices | ForEach-Object { Write-Error "  - $_" }
}

# Exit with appropriate code
if ($targetStarted) {
    exit 0
}
else {
    exit 1
}
