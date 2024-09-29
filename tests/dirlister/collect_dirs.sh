#!/usr/bin/env bash

# Define the output file
output_file="$HOME/codeWS/codeWS_directories.txt"

# Create the file if it does not exist
touch "$output_file"

# Clear the contents of the file
> "$output_file"

# Loop through all directories inside ~/codeWS
for dir in ~/codeWS/*; do
  # Check if it is a directory
  if [ -d "$dir" ]; then
    # Loop through the second level of directories
    for subdir in "$dir"/*; do
      # Check if it is a directory
      if [ -d "$subdir" ]; then
        # Print the path relative to ~/codeWS and append to the file
        echo "${subdir/#$HOME/}" >> "$output_file"
      fi
    done
  fi
done

echo "Directory paths have been saved to $output_file."
