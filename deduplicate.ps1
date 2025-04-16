param(
    [Parameter(Position=0)]
    [string]$Path = (Get-Location).Path
)

function ReplaceDuplicatesWithSymlinks {
    param(
        [string]$Path = $PWD.Path,
        [string[]]$IgnoredExtensions = @(".symlink", ".lnk", ".url")
    )

    begin {
        # Ensure we have an absolute path
        if (-not [System.IO.Path]::IsPathRooted($Path)) {
            $Path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $Path))
        }
        Write-Host "Scanning directory '$Path' for duplicate files..."
        $fileHashes = @{}
    }

    process {
        Get-ChildItem -Path $Path -File -Recurse | ForEach-Object {
            $currentFile = $_
            $skip = $false
            $filePath = "'$($currentFile.FullName)'"

            # Skip files with ignored extensions
            foreach ($ext in $IgnoredExtensions) {
                if ($currentFile.Name -like "*$ext") {
                    Write-Host "Ignoring $($ext) file: $filePath"
                    $skip = $true
                }
            }

            if (Test-Path -Path $currentFile.FullName -PathType Leaf) {
                $fileItem = Get-Item $currentFile.FullName
                $isSymlink = $fileItem.Attributes -match "ReparsePoint"
                if ($isSymlink) {
                    Write-Host "Ignoring symlink: $filePath"
                    $skip = $true
                }
            }

            if (-not $skip) {
                $hash = Get-FileHash -Path $currentFile.FullName -Algorithm MD5 # Calculate MD5 hash
    
                Write-Host "$filePath ($($hash.Hash))"
                
                if (-not $fileHashes.ContainsKey($hash.Hash)) {
                    $fileHashes[$hash.Hash] = @() # Group files by hash
                }
                $fileHashes[$hash.Hash] += $currentFile
            }
        }

        # Count unique files and duplicates
        $uniqueFilesCount = 0
        $duplicateFilesCount = 0
        
        foreach ($hash in $fileHashes.Keys) {
            $filesWithSameHash = $fileHashes[$hash].Count
            if ($filesWithSameHash -eq 1) {
                $uniqueFilesCount++
            } else {
                $uniqueFilesCount++  # Count the original file as unique
                $duplicateFilesCount += ($filesWithSameHash - 1)  # Count the rest as duplicates
            }
        }

        # Check if there are any duplicates
        if ($duplicateFilesCount -eq 0) {
            Write-Host "No duplicates found. Nothing to deduplicate."
            return
        }
        
        Write-Host "Deduplicating $($uniqueFilesCount + $duplicateFilesCount) Files (Unique: $uniqueFilesCount Duplicates: $duplicateFilesCount)..."

        # Process groups with duplicates
        foreach ($hash in $fileHashes.Keys) {
            $files = $fileHashes[$hash]
            if ($files.Count -gt 1) {
                # Keep first file as reference
                $referenceFile = $files[0]
                
                # Replace duplicates with symlinks
                for ($i = 1; $i -lt $files.Count; $i++) {
                    $duplicate = $files[$i]
                    $duplicatePath = "'$($duplicate.FullName)'"
                    $referencePath = "'$($duplicate.FullName)'"
                    
                    try {
                        Remove-Item -Path "$($duplicate.FullName)" -Force # Delete existing file

                        Write-Host "Creating symlink: $duplicatePath ->\n\t'$referencePath"

                        New-Item -ItemType SymbolicLink -Path "$($duplicate.FullName)" -Target "$($referenceFile.FullName)" -Force
                    }
                    catch {
                        Write-Error "Failed to process $($duplicatePath): $($_)"
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