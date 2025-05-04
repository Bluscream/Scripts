#!/bin/bash

# region UNRAID_PREP
un-get update
un-get upgrade
# un-get install crc32
# endregion UNRAID_PREP

# Configuration
SOURCE_DIR="_UNSORTIERT/"
DATE_COMMAND="exiftool -DateTimeOriginal -d %Y/%m/%d/%H%M%S%%le"
FALLBACK_DATE="stat -c '%Y/%m/%d/%H%M%S'"

# Process each file
for filepath in "$SOURCE_DIR"*; do
    # Skip directories
    [ -f "$filepath" ] || continue
    
    # Get original path for metadata storage
    orig_path=$(readlink -f "$filepath")
    
    # Try to get date from metadata first
    date_str=$($DATE_COMMAND "$filepath" 2>/dev/null)
    
    # Fallback to creation time if metadata date unavailable
    if [ $? -ne 0 ]; then
        date_str=$($FALLBACK_DATE "$filepath")
    fi
    
    # Extract year/month/day from date string
    IFS="/" read -r year month day <<< "$date_str"
    
    # Create destination directory structure
    dest_dir="./$year/$month/$day"
    mkdir -p "$dest_dir"
    
    # Calculate CRC32 hash
    crc32=$(md5sum "$filepath" | cut -d' ' -f1)
    
    # Get file extension
    ext="${filepath##*.}"
    
    # Construct destination filename
    dest_filename="$crc32.$ext"
    dest_path="$dest_dir/$dest_filename"
    
    # Add original path to metadata
    exiftool "-OriginalPath=$orig_path" "$filepath"
    
    # Move file to destination
    mv "$filepath" "$dest_path"
    
    echo "Moved $filepath to $dest_path"
done