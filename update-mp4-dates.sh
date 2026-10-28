#!/bin/bash

# 1. Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <path_to_directory> <date_value>"
    echo "Format: YYYY/MM/DD"
    echo "Example: $0 /home/user/videos 2026/04/28"
    exit 1
fi

TARGET_DIR="$1"
INPUT_DATE="$2"

# 2. Convert slashes to colons for exiftool compatibility, and append midnight
FORMATTED_DATE="${INPUT_DATE//\//:}"
NEW_DATE="${FORMATTED_DATE} 00:00:00"

# 3. Check if the target directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

# 4. Check if exiftool is installed
if ! command -v exiftool &> /dev/null; then
    echo "Error: 'exiftool' is not installed."
    echo "Please install it first:"
    echo "  - Debian/Ubuntu: sudo apt install libimage-exiftool-perl"
    echo "  - macOS: brew install exiftool"
    echo "  - RHEL/CentOS: sudo dnf install perl-Image-ExifTool"
    exit 1
fi

echo "Updating dates for all .mp4 files in: $TARGET_DIR"
echo "Setting metadata and file system dates to: $NEW_DATE"

# 5. Execute exiftool
# -ext mp4             : Process only files with the .mp4 extension
# -AllDates=           : Updates internal metadata (CreateDate, ModifyDate, DateTimeOriginal)
# -FileModifyDate=     : Updates the OS file system modification date
# -overwrite_original  : Prevents exiftool from creating duplicate "_original" backup files
exiftool -ext mp4 -AllDates="$NEW_DATE" -FileModifyDate="$NEW_DATE" -overwrite_original "$TARGET_DIR"

echo "Done."
