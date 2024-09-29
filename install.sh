#!/usr/bin/env bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (e.g., using sudo)."
    exit 1
fi

# Required dependencies
REQUIRED_COMMANDS=("git" "nmcli" "msmtp" "ssh" "rsync" "gh")

# Check for required commands
missing_packages=()
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$cmd is required but not installed."
        missing_packages+=("$cmd")
    fi
done

# If any dependencies are missing, inform the user
if [ ${#missing_packages[@]} -gt 0 ]; then
    echo "The following packages are missing and need to be installed:"
    echo "${missing_packages[@]}"
    echo "Please install them using your package manager. For example, on Debian/Ubuntu:"
    echo "sudo apt update && sudo apt install ${missing_packages[@]}"
    exit 1
else
    echo "All required dependencies are installed."
fi

# Copy the script to /usr/local/bin
INSTALL_PATH="/usr/local/bin/auto_git_update"
SOURCE_SCRIPT="auto_git_update.sh"

if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "Error: The source script '$SOURCE_SCRIPT' was not found in the current directory."
    exit 1
fi

# Make the script executable
chmod +x "$SOURCE_SCRIPT"

# Copy to /usr/local/bin
cp "$SOURCE_SCRIPT" "$INSTALL_PATH" && echo "Script installed successfully at $INSTALL_PATH"

# Provide usage instructions
echo "You can now run the script using the command 'auto_git_update'."

