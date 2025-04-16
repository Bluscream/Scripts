param(
    [Parameter(Position=0)]
    [string]$Path = (Get-Location).Path
)

function WriteHashesToFile {
    param(
        [hashtable]$fileHashes,
        [string]$fileName = ".\hashes.md5"
    )

    # Sort the file hashes by path for consistent output
    $sortedHashes = $fileHashes.GetEnumerator() | 
                    Sort-Object { $_.Value.Path } | 
                    ForEach-Object {
                        "$($_.Key)`t$($_.Value.Path)"
                    }

    # Write the sorted hashes to the specified file
    $sortedHashes | Out-File -FilePath $fileName -Encoding utf8 -Force

    Write-Host "Wrote $($sortedHashes.Count) file hashes to $fileName"
}


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
        $totalSize = 0
        $totalFiles = 0
        $dirname = Split-Path -Path $Path -Leaf
        $md5FilePath = Join-Path -Path $Path -ChildPath "$dirname.md5"
        if (-not (Test-Path -Path $md5FilePath)) {
            New-Item -Path $md5FilePath -ItemType File -Force | Out-Null # Create the MD5 file if it doesn't exist
            Write-Host "Created new MD5 file: $md5FilePath"
        }
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
                # Get file size and add to total
                $fileSize = $currentFile.Length
                $totalSize += $fileSize
                $fileSizeStr = "{0:N2} MB" -f ($fileSize / 1MB)

                $hash = Get-FileHash -Path $currentFile.FullName -Algorithm MD5 # Calculate MD5 hash
    
                Write-Host "$filePath $fileSizeStr ($($hash.Hash))"

                # $hashEntry = "$($hash.Hash)`t$($currentFile.FullName)"
                # $existingEntries = Get-Content -Path $md5FilePath -ErrorAction SilentlyContinue
                # $entryExists = $false
                # $updatedContent = @()
                # foreach ($line in $existingEntries) {
                #     if ($line -match "^$($hash.Hash)") { # If line starts with the same hash, replace it
                #         $updatedContent += $hashEntry
                #         $entryExists = $true
                #     } else {
                #         $updatedContent += $line
                #     }
                # }
                # if (-not $entryExists) { # If the hash entry doesn't exist, add it
                #     $updatedContent += $hashEntry
                # }
                # $updatedContent | Set-Content -Path $md5FilePath # Write the updated content back to the MD5 file
                
                if (-not $fileHashes.ContainsKey($hash.Hash)) {
                    $fileHashes[$hash.Hash] = @() # Group files by hash
                }
                $fileHashes[$hash.Hash] += $currentFile
            }
        }

        WriteHashesToFile -fileHashes $fileHashes -fileName $md5FilePath

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
        $totalFiles = $uniqueFilesCount + $duplicateFilesCount

        # Check if there are any duplicates
        if ($duplicateFilesCount -eq 0) {
            Write-Host "No duplicates found. Nothing to deduplicate."
            return
        }
        $fileSizeStr = "{0:N2} MB" -f ($totalSize / 1MB)
        Write-Host "Deduplicating $totalFiles Files with a total size of $fileSizeStr (Unique: $uniqueFilesCount Duplicates: $duplicateFilesCount)..."

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

                        # Subtract the size of the duplicate file from the total size
                        $totalSize -= $duplicate.Length
                    }
                    catch {
                        Write-Error "Failed to process $($duplicatePath): $($_)"
                    }
                }
            }
        }
    }

    end {
        $fileSizeStr = "{0:N2} MB" -f ($totalSize / 1MB)
        Write-Host "Processed $totalFiles files. Final Size: $fileSizeStr"
    }
}

ReplaceDuplicatesWithSymlinks -Path $Path