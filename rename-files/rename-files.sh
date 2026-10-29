#!/bin/bash

# Default flag values
REMOVE_WA=0
NEW_DATE=""
RENUMBER=0
PATTERN="IMG-*"

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
        -p|--pattern)
            PATTERN="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -w, --remove-wa       Remove 'WA' from the filename"
            echo "  -d, --date STRING     Replace the YYYYMMDD date with STRING"
            echo "  -r, --renumber        Renumber the index starting at 0000 and close gaps"
            echo "  -p, --pattern GLOB    Files to process (default: 'IMG-*')"
            echo "  -h, --help            Show this help message"
            echo
            echo "Renumbering understands these index styles:"
            echo "  IMG-20231025-WA0007.jpg  ->  IMG-20231025-0000.jpg"
            echo "  Holiday_0007.mp4         ->  Holiday_0000.mp4"
            echo "  Holiday (7).mp4          ->  Holiday_0000.mp4"
            exit 0
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

# Collect matching files in natural order, so "Name (2)" comes before "Name (10)"
FILES=()
for FILE in $PATTERN; do
    # Skip if no matching files are found, and skip directories
    [ -f "$FILE" ] || continue
    FILES+=("$FILE")
done
if [[ ${#FILES[@]} -gt 0 ]]; then
    mapfile -d '' FILES < <(printf '%s\0' "${FILES[@]}" | sort -zV)
fi

INDEX=0

for FILE in "${FILES[@]}"; do
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
        if [[ "$BASENAME" =~ ^(.*)(\ \([0-9]+\)|_[0-9]+)$ ]]; then
            # "Name (7)" or "Name_0007" -> "Name_0000"
            BASENAME=$(printf "%s_%04d" "${BASH_REMATCH[1]}" "$INDEX")
        elif [[ "$BASENAME" == *-* ]]; then
            # "IMG-20231025-WA0007" -> "IMG-20231025-0000" (everything after the last dash is the index)
            BASENAME=$(printf "%s-%04d" "${BASENAME%-*}" "$INDEX")
        else
            echo "Warning: No index found in '$FILE'. Skipping."
            continue
        fi
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
