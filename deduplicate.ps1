param(
    [Parameter(Position=0)]
    [string]$Path = (Get-Location).Path
)

function WriteHashesToFile {
    param(
        [hashtable]$fileHashes,
        [string]$fileName = ".\hashes.md5"
    )

    # Create a sorted list of hash entries for the md5 file
    $sortedHashes = @()


    
    foreach ($hash in $fileHashes.Keys) {
        $files = $fileHashes[$hash]
        # $sortedFiles = $files | Sort-Object -Property FullName
        foreach ($file in $files) {
            $sortedHashes += "$hash`t$($file.FullName)"
        }
    }

    # Write the sorted hashes to the specified file
    $sortedHashes | Out-File -FilePath $fileName -Encoding utf8 -Force

    Write-Host "Wrote $($sortedHashes.Count) file hashes to $fileName"
}

function ReplaceSymlinksWithCopies {
    param(
        [string]$Path = $PWD.Path
    )

    begin {
        # Ensure we have an absolute path
        if (-not [System.IO.Path]::IsPathRooted($Path)) {
            $Path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $Path))
        }
        Write-Host "Scanning directory '$Path' for symlinks to replace with copies..."
        $replacedCount = 0
        $totalSize = 0
    }

    process {
        Get-ChildItem -Path $Path -File -Recurse | ForEach-Object {
            $currentFile = $_
            $filePath = $currentFile.FullName

            # Check if the file is a symlink
            if (Test-Path -Path $filePath -PathType Leaf) {
                $fileItem = Get-Item $filePath
                $isSymlink = $fileItem.Attributes -match "ReparsePoint"
                
                if ($isSymlink) {
                    Write-Host "Found symlink: '$filePath'"
                    
                    # Get the target of the symlink
                    $targetPath = [System.IO.Path]::GetFullPath((Get-Item $filePath).Target)
                    
                    if (Test-Path -Path $targetPath -PathType Leaf) {
                        # Create a backup of the symlink
                        $backupPath = "$filePath.symlink_backup"
                        Copy-Item -Path $filePath -Destination $backupPath -Force
                        
                        # Remove the symlink
                        Remove-Item -Path $filePath -Force
                        
                        # Copy the target file to the original symlink location
                        Copy-Item -Path $targetPath -Destination $filePath -Force
                        
                        $fileSize = (Get-Item $filePath).Length
                        $totalSize += $fileSize
                        $replacedCount++
                        
                        Write-Host "Replaced symlink with copy of target file: '$targetPath' -> '$filePath' ($('{0:N2}' -f ($fileSize / 1MB)) MB)"
                    } else {
                        Write-Warning "Target of symlink does not exist or is not a file: '$targetPath'"
                    }
                }
            }
        }
    }

    end {
        Write-Host "Replaced $replacedCount symlinks with copies, total size: $('{0:N2}' -f ($totalSize / 1MB)) MB"
    }
}


function ReplaceDuplicatesWithSymlinks {
    param(
        [string]$Path = $PWD.Path,
        [string[]]$IgnoredExtensions = @(".symlink", ".lnk", ".url", ".md5")
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

function DeduplicateAllLocalDrives {
    [CmdletBinding()]
    param()

    process {
        # Get all local fixed drives
        $localDrives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        
        if ($localDrives.Count -eq 0) {
            Write-Host "No local drives found."
            return
        }
        
        Write-Host "Found $($localDrives.Count) local drives to deduplicate."
        
        # Process each drive
        foreach ($drive in $localDrives) {
            $drivePath = "$($drive.DeviceID)\"
            Write-Host "Deduplicating $($drive.VolumeName) ($drivePath)"
            
            try {
                # Call the main deduplication function for each drive
                ReplaceDuplicatesWithSymlinks -Path $drivePath
            }
            catch {
                Write-Error "Failed to deduplicate drive $drivePath`: $_"
            }
        }
    }

    end {
        Write-Host "Completed deduplication of all local drives."
    }
}

# DeduplicateAllLocalDrives

ReplaceDuplicatesWithSymlinks -Path $Path