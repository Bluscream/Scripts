# List all network adapters and their properties in YAML format
$adapters = Get-NetAdapter | Select-Object *

$ignoredProps = @('CimInstanceProperties', 'CimSystemProperties')

Write-Output "network_adapters:"
foreach ($adapter in $adapters) {
    Write-Output "  - name: '$($adapter.Name)'"
    foreach ($property in $adapter.PSObject.Properties) {
        if ($property.Name -ne 'Name' -and -not ($ignoredProps -contains $property.Name)) {
            $value = $property.Value
            if ($null -eq $value) { $value = '' }
            $escapedValue = $value -replace '"', '\"'
            Write-Output "    $($property.Name): '$escapedValue'"
        }
    }
}
