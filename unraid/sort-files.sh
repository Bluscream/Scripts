#!/bin/bash

# Configuration
SOURCE_DIR="_UNSORTIERT/"
TARGET_BASE="organized/"

# Create target base directory if it doesn't exist
mkdir -p "$TARGET_BASE"

# Process each file in the source directory
find "$SOURCE_DIR" -type f | while read -r filepath; do
    # Get relative path (remove SOURCE_DIR prefix)
    rel_path="${filepath#$SOURCE_DIR}"
    
    # Try to get EXIF date first
    exif_date=$(exiftool -DateTimeOriginal -d "%Y/%m/%d" "$filepath" 2>/dev/null | awk '{print $3}')
    
    # Fallback to modification date if no EXIF date exists
    if [ -z "$exif_date" ]; then
        mod_time=$(stat -c "%Y" "$filepath")
        date_str=$(date -d @"$mod_time" "+%Y/%m/%d")
    else
        date_str="$exif_date"
    fi
    
    # Extract extension
    ext="${filepath##*.}"
    if [ "$ext" = "$filepath" ]; then
        ext=""
    else
        ext=".$ext"
    fi
    
    # Generate CRC32 hash
    crc32=$(crc32 "$filepath" | cut -d' ' -f1)
    
    # Construct target path
    year_dir="${date_str%%/*}"
    month_dir="${date_str#*/}"
    day_dir="${date_str##*/}"
    target_dir="$TARGET_BASE$year_dir/$month_dir/$day_dir"
    target_filename="$crc32$ext"
    target_path="$target_dir/$target_filename"
    
    # Create target directory structure
    mkdir -p "$target_dir"
    
    # Add original path to metadata
    exiftool "-OriginalPath=$rel_path" "$filepath"
    
    # Move file to new location
    mv -i "$filepath" "$target_path"
    
    echo "Moved: $filepath -> $target_path"
done