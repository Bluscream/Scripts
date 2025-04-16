param(
    [Parameter(Position=0)]
    [string]$Path = (Get-Location).Path
)



function Get-PSVersion {
    if (test-path variable:psversiontable) {$psversiontable.psversion} else {[version]"1.0.0.0"}
}

$PSVersion = Get-PSVersion
if ($PSVersion.Major -lt 6) {
    Write-Host "This script requires PowerShell 6 or higher. Current version: $PSVersion"
    exit
}

Import-Module Symlink

function ReplaceDuplicatesWithSymlinks {
    param(
        [string]$Path = $PWD.Path
    )

    begin {
        Write-Host "Scanning directory '$Path' for duplicate files..."
        $fileHashes = @{}
    }

    process {
        Get-ChildItem -Path $Path -File -Recurse | ForEach-Object {
            $currentFile = $_

            # Check if the file is a symlink and ignore if true
            if ((Get-Item $currentFile.FullName -Force | Where-Object {$_.Attributes -contains "ReparsePoint"}) -or ($currentFile.Name -like "*.symlink")) {
                Write-Host "Ignoring symlink: $($currentFile.FullName)"
                continue
            }
            
            # Calculate MD5 hash
            $hash = Get-FileHash -Path $currentFile.FullName -Algorithm MD5

            Write-Host "File: $($currentFile.FullName) | Hash: $($hash.Hash)"
            
            # Group files by hash
            if (-not $fileHashes.ContainsKey($hash.Hash)) {
                $fileHashes[$hash.Hash] = @()
            }
            
            $fileHashes[$hash.Hash] += $currentFile
        }

        # Process groups with duplicates
        foreach ($hash in $fileHashes.Keys) {
            $files = $fileHashes[$hash]
            if ($files.Count -gt 1) {
                # Keep first file as reference
                $referenceFile = $files[0]
                
                # Replace duplicates with symlinks
                for ($i = 1; $i -lt $files.Count; $i++) {
                    $duplicate = $files[$i]
                    
                    try {
                        Remove-Item -Path "$duplicate.FullName" -Force # Delete existing file

                        Write-Host "Creating symlink: '$($duplicate.DirectoryName)\$($duplicate.Name)' ->\n\t'$($referenceFile.FullName)'"
                        
                        New-Symlink -Path "$($duplicate.FullName)" -Name "$($duplicate.Name)" -Target "$($referenceFile.FullName)" # Create symlink pointing to reference file
                        Build-Symlink -All
                    }
                    catch {
                        Write-Error "Failed to process $($duplicate.FullName): $_"
                    }
                }
            }
        }
    }

    end {
        Write-Host "Processing completed."
    }
}

ReplaceDuplicatesWithSymlinks -Path $Path