param(
    [Parameter(Mandatory)]
    [string]$InputXmlPath
)

# Define triggers and their XML
$triggers = @(
    @{ Name = 'BootTrigger'; Xml = '<BootTrigger><Enabled>true</Enabled></BootTrigger>' },
    @{ Name = 'LogonTrigger'; Xml = '<LogonTrigger><Enabled>true</Enabled></LogonTrigger>' },
    @{ Name = 'IdleTrigger'; Xml = '<IdleTrigger><Enabled>true</Enabled></IdleTrigger>' },
    @{ Name = 'RemoteConnect'; Xml = '<SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>RemoteConnect</StateChange></SessionStateChangeTrigger>' },
    @{ Name = 'ConsoleConnect'; Xml = '<SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>ConsoleConnect</StateChange></SessionStateChangeTrigger>' },
    @{ Name = 'RemoteDisconnect'; Xml = '<SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>RemoteDisconnect</StateChange></SessionStateChangeTrigger>' },
    @{ Name = 'ConsoleDisconnect'; Xml = '<SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>ConsoleDisconnect</StateChange></SessionStateChangeTrigger>' },
    @{ Name = 'SessionLock'; Xml = '<SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionLock</StateChange></SessionStateChangeTrigger>' },
    @{ Name = 'SessionUnlock'; Xml = '<SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>' },
    @{ Name = 'WindowsUpdateFinished'; Xml = "<EventTrigger><Enabled>true</Enabled><Subscription>&lt;QueryList&gt;&lt;Query&gt;&lt;Select Path='System'&gt;*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and (EventID=19)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription></EventTrigger>" }
)

# Load the XML
[xml]$xml = Get-Content $InputXmlPath

# Get base task name
$taskName = [System.IO.Path]::GetFileNameWithoutExtension($InputXmlPath)

foreach ($trigger in $triggers) {
    $newXml = $xml.Clone()
    # Ensure Triggers node is an XmlElement
    $triggersNode = $newXml.Task.Triggers
    if ($triggersNode -is [string] -or -not $triggersNode) {
        # Remove the string node if present
        if ($triggersNode) {
            $parent = $newXml.Task
            $parent.RemoveChild($parent.Triggers) | Out-Null
        }
        $triggersNode = $newXml.CreateElement('Triggers', $newXml.DocumentElement.NamespaceURI)
        $newXml.Task.AppendChild($triggersNode) | Out-Null
    } else {
        $triggersNode.RemoveAll()
    }
    # Import the new trigger
    $triggerNode = [xml]$trigger.Xml
    $imported = $newXml.ImportNode($triggerNode.DocumentElement, $true)
    $triggersNode.AppendChild($imported) | Out-Null
    # Namespace manager for XPath
    $nsmgr = New-Object System.Xml.XmlNamespaceManager $newXml.NameTable
    $nsmgr.AddNamespace('ns', $newXml.DocumentElement.NamespaceURI)

    # Find RegistrationInfo and URI using namespace
    $regInfo = $newXml.SelectSingleNode('//ns:RegistrationInfo', $nsmgr)
    if (-not $regInfo) {
        $regInfo = $newXml.CreateElement('RegistrationInfo', $newXml.DocumentElement.NamespaceURI)
        $newXml.Task.AppendChild($regInfo) | Out-Null
    }
    $uriNode = $regInfo.SelectSingleNode('ns:URI', $nsmgr)
    if (-not $uriNode) {
        $uriNode = $newXml.CreateElement('URI', $newXml.DocumentElement.NamespaceURI)
        $regInfo.AppendChild($uriNode) | Out-Null
        $uriNode.InnerText = "\\$($taskName)"
    }
    $parts = $uriNode.InnerText.Trim('\') -split '\\'
    $parts[-1] = $trigger.Name
    $uriNode.InnerText = '\' + ($parts -join '\')

    # Save new XML
    $outPath = Join-Path -Path (Split-Path $InputXmlPath) -ChildPath ("${taskName}_$($trigger.Name).xml")
    $newXml.Save($outPath)
    Write-Host "Created: $outPath"
# Read the file as text, replace all instances of xmlns="" with empty, and save it again
    $fileContent = Get-Content -Path $outPath -Raw
    $fileContent = $fileContent -replace 'xmlns=""', ''
    $fileContent = $fileContent -replace '\{eventname\}', $trigger.Name
    Set-Content -Path $outPath -Value $fileContent

    # Register the scheduled task at the specified URI path
    $taskPath = $uriNode.InnerText
    try {
        Register-ScheduledTask -Xml $fileContent -TaskName $trigger.Name -TaskPath (Split-Path $taskPath -Parent) -Force | Out-Null
        Write-Host "Task registered at $taskPath"
    } catch {
        Write-Host "Failed to register task at $taskPath"
        Write-Host $_.Exception.Message
    }
}
