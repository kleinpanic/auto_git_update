#!/usr/bin/env bash

# Check if required commands are available
for cmd in git nmcli msmtp ssh scp; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$cmd is required but not installed. Exiting."
        exit 1
    fi
done

# Configuration
TXT_FILE="/home/klein/.config/setup/autogitupdate.txt"
PHONE_NUMBER="2673479614@vtext.com"  # Verizon SMS gateway
EMAIL="kleinpanic@gmail.com"
SUBJECT="Git Update Report"
REPORT="/tmp/git_update_report.txt"  # Full detailed report
SUMMARY_REPORT="/tmp/git_update_summary.txt"  # Full summary report
SMS_REPORT="/tmp/git_update_sms.txt"  # Minimal SMS summary
SSH_HOST="eulerpi"  # Alias for the SSH connection
SSH_DIR="/home/klein/reports"  # Remote directory to store the report

# Function to ensure a file exists and has the correct permissions
ensure_file() {
    local file="$1"
    local permissions="$2"

    if [ ! -f "$file" ]; then
        touch "$file"
        chmod "$permissions" "$file"
        echo "Created $file with permissions $permissions"
    else
        chmod "$permissions" "$file"
        echo "Ensured $file has permissions $permissions"
    fi
}

# Ensure the report files exist and have the correct permissions
ensure_file "$REPORT" 600
ensure_file "$SUMMARY_REPORT" 600
ensure_file "$SMS_REPORT" 600

# Function to check WiFi connection and internet availability
check_wifi() {
    nmcli -t -f ACTIVE,SSID dev wifi | grep -q "^yes" && ping -c 1 8.8.8.8 &>/dev/null
    return $?
}

# Function to fetch and clean repo directories from text file
get_repo_dirs() {
    local valid_dirs=()
    local invalid_dirs=()

    while IFS= read -r repo_dir; do
        if [ -d "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
            valid_dirs+=("$repo_dir")
        else
            invalid_dirs+=("$repo_dir")
        fi
    done < "$TXT_FILE"

    # Log and remove invalid entries from the file
    if [ ${#invalid_dirs[@]} -gt 0 ]; then
        for dir in "${invalid_dirs[@]}"; do
            echo "$dir does not exist or is not a valid git repository. Removing from $TXT_FILE" >> "$REPORT"
            echo "$dir does not exist or is not a valid git repository. Removing from $TXT_FILE"
            sed -i "\|$dir|d" "$TXT_FILE"
        done
    fi

    # Return valid directories
    echo "${valid_dirs[@]}"
}

# Function to update, commit, and (if connected) push the changes
update_repo() {
    local repo_dir="$1"
    local repo_number="$2"
    cd "$repo_dir" || return

    echo "Processing repository: $repo_dir" >> "$REPORT"
    echo "Processing repository: $repo_dir"

    git fetch origin
    if ! git merge origin/main --no-commit --no-ff; then
        echo "Merge conflict detected in $repo_dir" >> "$REPORT"
        echo "Merge conflict in $repo_dir" >> "$SUMMARY_REPORT"
        echo "repo: $repo_number, C" >> "$SMS_REPORT"
        git merge --abort
        return 1
    fi

    if git diff-index --quiet HEAD --; then
        echo "No changes detected in $repo_dir" >> "$REPORT"
        echo "No changes in $repo_dir" >> "$SUMMARY_REPORT"
        echo "repo: $repo_number, NC" >> "$SMS_REPORT"
        return 0
    fi

    git add -A
    git commit -m "Automated update"

    # Check if connected to the internet before pushing
    if check_wifi; then
        echo "Internet is available. Attempting to push changes..." >> "$REPORT"
        if ! git push origin main; then
            echo "Failed to push changes in $repo_dir" >> "$REPORT"
            echo "Failed to push changes in $repo_dir" >> "$SUMMARY_REPORT"
            echo "repo: $repo_number, ERR" >> "$SMS_REPORT"
            return 1
        else
            echo "Changes pushed successfully in $repo_dir" >> "$REPORT"
            echo "Changes pushed in $repo_dir" >> "$SUMMARY_REPORT"
            echo "repo: $repo_number, P" >> "$SMS_REPORT"
        fi
    else
        echo "No internet connection. Changes committed locally in $repo_dir" >> "$REPORT"
        echo "Changes committed locally in $repo_dir" >> "$SUMMARY_REPORT"
        echo "repo: $repo_number, LC" >> "$SMS_REPORT"
    fi
}

# Start of the script
echo "Starting auto git update script on $(date)" > "$REPORT"
echo "Git Update Summary: $(date)" > "$SUMMARY_REPORT"
echo "(GIT Report), $(date)" > "$SMS_REPORT"

# Fetch valid repositories
repo_dirs=($(get_repo_dirs))  # Convert to array properly
repo_number=1

# Loop through each valid directory
for repo_dir in "${repo_dirs[@]}"; do
    update_repo "$repo_dir" "$repo_number"
    repo_number=$((repo_number + 1))
done

# Function to send the report via text message
send_text() {
    /usr/bin/msmtp -a default -t <<EOF
To: $PHONE_NUMBER
From: $EMAIL
Subject: $SUBJECT

$(cat $SMS_REPORT)
EOF
    return $?
}

# Function to copy the report over SSH
copy_report_ssh() {
    ssh "$SSH_HOST" "mkdir -p $SSH_DIR"
    scp "$SUMMARY_REPORT" "$SSH_HOST:$SSH_DIR/"
    scp "$REPORT" "$SSH_HOST:$SSH_DIR/"
    return $?
}

# Main logic for text, SSH handling, and local storage
if check_wifi; then
    echo "WiFi is connected. Attempting to send text message and SSH transfer..."
    send_text && echo "Text message sent successfully." || echo "Failed to send text message."
    copy_report_ssh && echo "Reports successfully copied over SSH." || echo "Failed to copy report over SSH."
else
    echo "No WiFi connection detected. Waiting for connection to push changes..."
    while ! check_wifi; do
        sleep 60  # Wait for a minute before checking again
    done

    echo "WiFi is now connected. Pushing changes..."
    for repo_dir in "${repo_dirs[@]}"; do
        cd "$repo_dir" || continue
        git push origin main
    done

    send_text && echo "Text message sent successfully." || echo "Failed to send text message."
    copy_report_ssh && echo "Reports successfully copied over SSH." || echo "Failed to copy report over SSH."
fi

# Clean up local reports if SSH was successful
if [[ $? -eq 0 ]]; then
    echo "SSH transfer succeeded. Deleting local reports."
    rm -f "$REPORT" "$SUMMARY_REPORT"
else
    echo "SSH transfer failed. Keeping local reports for troubleshooting."
fi
