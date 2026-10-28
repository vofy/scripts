#!/bin/bash

# Recursively copies files from input directory to output directory, while compressing video files using HandBrakeCLI (output to .mkv). Incomplete files are named .tmp/.tmp.mkv until finalized, in order to prevent incomplete files from being confused with complete files.
# Uses exiftool to copy metadata from the source file to the encoded file.

if [ $# -ne 3 ]; then
  echo "Usage: $(basename $0) <input> <output> <preset>"
  exit 1
fi

if [ ! -d "$1" ]; then
  echo "Directory does not exist"
  exit 1
fi

# Check if exiftool is installed
if ! command -v exiftool &> /dev/null; then
  echo "Error: exiftool is not installed. Please install it to copy metadata."
  exit 1
fi

format='.mp4' # File extension to use for output video files
match='\.mkv$|\.mp4$|\.avi$|\.mov$|\.m4v$|\.mpg$' # Regex used to differentiate video files from non-video files

# Remove trailing slash from args for consistency
arg1=$(echo "$1" | sed -E "s/\/$//")
arg2=$(echo "$2" | sed -E "s/\/$//")

input=$(find "$arg1" -type f | sort)
input_cp=$(echo "$input" | grep -vE $match)
input_vid=$(echo "$input" | grep -E $match)
preset=$(echo "$3" | sed -E "s/.*\///g" | sed -E "s/\.[^.]+$//") # (IMPORTANT) Assumes HandBrake preset name is same as file name

# Compressing video files
if [ ! "$input_vid" = "" ]; then
  echo "$input_vid" | while read inp; do
    out=$(echo "$inp" | sed "s|$arg1|$arg2|" | sed -E "s/\.[^.]+$/$format/")
    dir=$(echo "$out" | sed -E "s/\/[^\/]+$//")
    tmp="$dir/.tmp$format"

    if [ ! -f "$out" ]; then
      echo ""
      echo "Compressing \"$inp\"..."
      mkdir -p "$dir" 2> /dev/null
      rm "$tmp" 2> /dev/null
      trap "exit 1" SIGINT
      
      # Compress the video
      flatpak run --command=HandBrakeCLI fr.handbrake.ghb --preset-import-file "$3" -Z "$preset" -i "$inp" -o "$tmp" < /dev/null 2> /dev/null && \
      mv "$tmp" "$out" && \
      
      # Copy EXIF and other metadata from original file to new file
      echo "Copying metadata for \"$out\"..." && \
      exiftool -tagsFromFile "$inp" -all:all -overwrite_original "$out" > /dev/null && \
      
      # Match standard OS file modification/access timestamps
      touch -r "$inp" "$out"
    fi
  done
fi
