#!/bin/bash

# Retroactively copies EXIF metadata and system timestamps from original video files
# to already compressed .mp4 output files.

if [ $# -ne 2 ]; then
  echo "Usage: $(basename $0) <input_directory> <output_directory>"
  exit 1
fi

if [ ! -d "$1" ] || [ ! -d "$2" ]; then
  echo "Error: Both input and output directories must exist."
  exit 1
fi

# Check if exiftool is installed
if ! command -v exiftool &> /dev/null; then
  echo "Error: exiftool is not installed. Please install it to copy metadata."
  exit 1
fi

format='.mp4' # The output format used by your previous script
match='\.mkv$|\.mp4$|\.avi$|\.mov$|\.m4v$|\.mpg$' 

# Remove trailing slash from args for consistency
arg1=$(echo "$1" | sed -E "s/\/$//")
arg2=$(echo "$2" | sed -E "s/\/$//")

input=$(find "$arg1" -type f | sort)
input_vid=$(echo "$input" | grep -E $match)

# Process video files
if [ ! "$input_vid" = "" ]; then
  echo "$input_vid" | while read inp; do
    # Calculate what the output file path should be based on the previous script's logic
    out=$(echo "$inp" | sed "s|$arg1|$arg2|" | sed -E "s/\.[^.]+$/$format/")

    if [ -f "$out" ]; then
      echo "Restoring metadata for \"$out\"..."
      
      # Copy EXIF and other metadata from original file to the existing output file
      exiftool -tagsFromFile "$inp" -all:all -overwrite_original "$out" > /dev/null
      
      # Match standard OS file modification/access timestamps
      touch -r "$inp" "$out"
    else
      echo "Warning: Compressed file not found for \"$inp\", skipping..."
    fi
  done
else
  echo "No video files found in the input directory."
fi
