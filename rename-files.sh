#!/bin/bash

# Default flag values
REMOVE_WA=0
NEW_DATE=""
RENUMBER=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -w|--remove-wa) 
            REMOVE_WA=1
            shift 
            ;;
        -d|--date) 
            NEW_DATE="$2"
            shift 2 
            ;;
        -r|--renumber) 
            RENUMBER=1
            shift 
            ;;
        -h|--help) 
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -w, --remove-wa     Remove 'WA' from the filename"
            echo "  -d, --date STRING   Replace the YYYYMMDD date with STRING"
            echo "  -r, --renumber      Renumber the index starting at 0000 and close gaps"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *) 
            echo "Unknown parameter: $1"
            exit 1 
            ;;
    esac
done

INDEX=0

# Iterate safely over files matching the standard IMG prefix
for FILE in IMG-*; do
    # Skip if no matching files are found
    [ -e "$FILE" ] || continue
    # Skip directories
    [ -f "$FILE" ] || continue

    # Extract the filename without extension and the extension itself
    BASENAME="${FILE%.*}"
    EXT="${FILE##*.}"
    
    # If the file has no extension, EXT will be the same as BASENAME
    if [[ "$BASENAME" == "$EXT" ]]; then
        EXT=""
    else
        EXT=".$EXT"
    fi

    # 1. Remove "WA" if the argument was passed
    if [[ $REMOVE_WA -eq 1 ]]; then
        BASENAME="${BASENAME//WA/}"
    fi

    # 2. Replace the date string if the argument was passed
    if [[ -n "$NEW_DATE" ]]; then
        # This regex looks for exactly 8 digits following "IMG-" and replaces them
        BASENAME=$(echo "$BASENAME" | sed -E 's/IMG-[0-9]{8}/IMG-'"$NEW_DATE"'/')
    fi

    # 3. Renumber the index if the argument was passed
    if [[ $RENUMBER -eq 1 ]]; then
        # Extract everything before the last dash (e.g., "IMG-20231025")
        PREFIX="${BASENAME%-*}"
        
        # Append the new zero-padded 4-digit index
        BASENAME=$(printf "%s-%04d" "$PREFIX" "$INDEX")
        ((INDEX++))
    fi

    # Construct the final target filename
    NEW_FILE="${BASENAME}${EXT}"

    # Only rename if the name actually changed to prevent unnecessary OS operations
    if [[ "$FILE" != "$NEW_FILE" ]]; then
        # Check if target file already exists to prevent overwriting
        if [[ -e "$NEW_FILE" ]]; then
            echo "Warning: Cannot rename '$FILE' to '$NEW_FILE' because it already exists. Skipping."
        else
            mv "$FILE" "$NEW_FILE"
            echo "Renamed: $FILE -> $NEW_FILE"
        fi
    fi
done

echo "Done."
