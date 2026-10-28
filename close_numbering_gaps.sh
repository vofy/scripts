#!/bin/bash

# 1. Initialize our starting number
counter=0

# 2. Loop through all files that end with "(something).mp4"
# The shell automatically sorts these alphabetically, which matches your number order.
for file in *"_"*"."*; do
    
    # Skip if it's not a real file
    [ -f "$file" ] || continue

    # 3. Extract the prefix.
    # This removes everything from the last " (" to the end of the filename.
    # Example: "Holiday (21).mp4" becomes "Holiday"
    prefix="${file% (*}"

    # 4. Format the new number with a leading zero (01, 02, ..., 10, 11)
    new_num=$(printf "%04d" "$counter")

    # 5. Construct the new filename
    new_file="${prefix}_${new_num}.mp4"

    # 6. Rename the file, but only if the name actually needs to change
    if [ "$file" != "$new_file" ]; then
        echo "Renaming: '$file'  ->  '$new_file'"
        
        # Using -n prevents accidentally overwriting an existing file
        mv -n "$file" "$new_file"
    else
        echo "Skipping: '$file' is already correct."
    fi

    # 7. Increment the counter for the next file
    ((counter++))
done

echo "Done! All gaps closed."
