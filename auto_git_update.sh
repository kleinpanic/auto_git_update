#!/usr/bin/env bash

# Declare the security variable
security_variable=2  # Change this value as needed (0, 1, or 2)

# Check the value of the security variable
if [ "$security_variable" -eq 0 ]; then
    echo "Error: security_variable is set to 0. Exiting the script."
    exit 1
fi

# If the security variable is 2, continue without any conditions
if [ "$security_variable" -eq 2 ]; then
    echo "security_variable is set to 2. Running the script without further checks."
else
    # If the security variable is 1, check if today is Friday
    DAY_OF_WEEK=$(date +%A)
    if [ "$DAY_OF_WEEK" = "Friday" ]; then
        echo "Today is Friday. Continuing with the script."
    else
        echo "Today is not Friday (Today is $DAY_OF_WEEK). Exiting the script."
        exit 0
    fi
fi

# Check if required commands are available
for cmd in git nmcli msmtp ssh scp gh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$cmd is required but not installed. Exiting."
        exit 1
    fi
done

# Configuration
TXT_FILE="/home/klein/.config/setup/autogitupdate.txt"
CREDENTIALS_FILE="$HOME/.config/setup/credentials.config"
REPORT="/tmp/git_update_report.txt"  # Full detailed report
SMS_REPORT="/tmp/git_update_sms.txt"  # Minimal SMS summary
SMS_CHAR_LIMIT=160  # Character limit for SMS messages
SSH_DIR="/home/klein/reports"

# Check for the existence of the configuration file
if [ ! -f "$TXT_FILE" ]; then
    echo "Error: Configuration file '$TXT_FILE' not found. Exiting the script."
    exit 1
fi

# Check if the credentials file exists
if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "Error: Credentials file '$CREDENTIALS_FILE' not found. Exiting the script."
    exit 1
fi

# Source the credentials from the config file
source "$CREDENTIALS_FILE"

# Validate that required variables are set
if [ -z "$EMAIL" ] || [ -z "$SSH_HOST" ] || [ -z "$PHONE_NUMBER" ]; then
    echo "Error: Missing required credentials (EMAIL, SSH_HOST, or PHONE_NUMBER) in '$CREDENTIALS_FILE'. Exiting the script."
    exit 1
fi

# Ensure the report files exist and have the correct permissions
ensure_file() {
    local file="$1"
    local permissions="$2"
    [ ! -f "$file" ] && touch "$file" && chmod "$permissions" "$file"
    chmod "$permissions" "$file"
}

ensure_file "$REPORT" 600
ensure_file "$SMS_REPORT" 600

# Function to check WiFi connection and internet availability
check_wifi() {
    nmcli -t -f ACTIVE,SSID dev wifi | grep -q "^yes" && ping -c 1 8.8.8.8 &>/dev/null
    return $?
}

get_repo_dirs() {
    local valid_dirs=()
    
    while IFS= read -r repo_dir; do
        # Trim whitespace and skip empty lines
        repo_dir=$(echo "$repo_dir" | xargs)
        if [[ -z "$repo_dir" || "$repo_dir" == \#* ]]; then
            continue
        fi
        # Check if the directory is valid and contains a .git folder
        if [ -d "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
            valid_dirs+=("$repo_dir")
        fi
    done < "$TXT_FILE"
    
    # Output only the valid directories without any additional text
    echo "${valid_dirs[@]}"
}

# Function to create GitHub repo if it doesn't exist and push changes
create_github_repo() {
    local repo_name="$1"
    local repo_dir="$2"
    local repo_number="$3"
    echo "Attempting to create GitHub repo for repo $repo_number ($repo_name)" >> "$REPORT"
    log_msg "Creating GitHub repository for repo $repo_number ($repo_name) using source: $repo_dir"
    
    # Attempt to create the repository via gh.
    # Capture the output and exit code.
    local gh_output
    if gh_output=$(gh repo create "$repo_name" --public --source="$repo_dir" --remote=origin --push 2>&1); then
        echo "Successfully created GitHub repository #$repo_number: $repo_name" >> "$REPORT"
        echo "Repo #$repo_number $repo_name: GHS" >> "$SMS_REPORT"
        echo "Success GHS"
        log_msg "GitHub repository $repo_name created successfully."
    else
        # Check if the output indicates that the repository already exists.
        if echo "$gh_output" | grep -qi "already exists"; then
            echo "Repository $repo_name already exists on GitHub." >> "$REPORT"
            log_msg "Repository $repo_name already exists on GitHub. Will attempt to add remote."
        else
            echo "Failed to create GitHub repository #$repo_number: $repo_name" >> "$REPORT"
            echo "Repo #$repo_number: GCF" >> "$SMS_REPORT"
            echo "GCF Repo"
            log_msg "Failed to create GitHub repository $repo_name. gh output: $gh_output"
            return 1
        fi
    fi
    
    # In either case, try to set the remote URL.
    git remote add origin "git@github.com:kleinpanic/$repo_name.git" 2>/dev/null || true
    git branch -M main
    if git push -u origin main; then
        echo "Existing repository #$repo_number pushed successfully to GitHub." >> "$REPORT"
        echo "Repo #$repo_number: PS" >> "$SMS_REPORT"
        echo "Repo PS"
        log_msg "Existing repository $repo_name pushed successfully."
    else
        echo "Failed to push the existing repository #$repo_number to GitHub." >> "$REPORT"
        echo "Repo #$repo_number: PF" >> "$SMS_REPORT"
        echo "Repo PF"
        log_msg "Push failed for repository $repo_name."
    fi
    return 0
}

# Function to check if a remote GitHub origin exists
check_github_remote() {
    if ! git remote get-url origin &>/dev/null; then
        echo "No 'origin' remote found." >> "$REPORT"
        return 1
    fi
    
    local remote_url
    remote_url=$(git remote get-url origin)
    if [[ "$remote_url" != *github.com* ]]; then
        echo "'origin' remote does not point to GitHub." >> "$REPORT"
        return 1
    fi
    
    local repo_name
    repo_name=$(basename "$remote_url" .git)
    local repo_owner
    repo_owner=$(basename "$(dirname "$remote_url")")
    local full_repo_name="$repo_owner/$repo_name"
    
    echo "Checking if GitHub repository '$full_repo_name' exists..." >> "$REPORT"
    
    if ! gh repo view "$full_repo_name" &>/dev/null; then
        echo "GitHub repository '$full_repo_name' does not exist or is not accessible." >> "$REPORT"
        return 1
    fi
    
    return 0
}

# Function to check if the repository is up-to-date
is_repo_up_to_date() {
    git remote update &>/dev/null
    if git status -uno | grep -q "Your branch is up to date"; then
        echo "Repository is up to date. No fetch needed."
        return 0
    else
        echo "Repository is not up to date. Fetching changes..."
        return 1
    fi
}

# Function to check if the .git folder is valid
is_valid_git_repo() {
    local repo_dir="$1"
    
    if [ ! -d "$repo_dir/.git" ]; then
        echo "Error: '.git' directory is missing in '$repo_dir'. Skipping this repository." >> "$REPORT"
        return 1
    fi

    # Check for essential .git files
    for file in HEAD config; do
        if [ ! -f "$repo_dir/.git/$file" ]; then
            echo "Error: Missing '$file' in '.git' directory of '$repo_dir'. Skipping this repository." >> "$REPORT"
            return 1
        fi
    done

    # Ensure the repository has at least one commit
    if ! git -C "$repo_dir" rev-parse HEAD &>/dev/null; then
        echo "Error: The repository in '$repo_dir' appears to be corrupt or does not have any commits." >> "$REPORT"
        return 1
    fi

    return 0
}

# A simple logging function to write timestamped messages
log_msg() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$REPORT"
}

update_repo() {
    local repo_dir="$1"
    local repo_number="$2"

    # Change directory into the repository.
    if ! cd "$repo_dir"; then
        log_msg "Repo #$repo_number: Unable to cd to $repo_dir"
        return 1
    fi
    log_msg "Processing repository #$repo_number at $repo_dir"

    # Validate that this is a proper git repository.
    if ! is_valid_git_repo "$repo_dir"; then
        log_msg "Repo #$repo_number: Invalid repository. Skipping."
        echo "Invalid .git" >> "$SMS_REPORT"
        return 1
    fi

    # If there are no commits, create an initial empty commit.
    if ! git rev-parse HEAD &>/dev/null; then
        log_msg "Repo #$repo_number: No commits found. Creating an initial empty commit."
        if ! git commit --allow-empty -m "Initial commit"; then
            log_msg "Repo #$repo_number: Failed to create initial commit."
            echo "Repo #$repo_number: No commit" >> "$SMS_REPORT"
            return 1
        fi
    fi

    # Check for a valid GitHub remote.
    local remote_available=true
    if ! check_github_remote; then
        log_msg "Repo #$repo_number: No valid GitHub remote detected."
        remote_available=false
        if check_wifi; then
            local repo_name
            repo_name=$(basename "$repo_dir")
            # First, check if a remote named "origin" exists.
            if git remote get-url origin &>/dev/null; then
                log_msg "Repo #$repo_number: Remote 'origin' exists; setting URL to git@github.com:kleinpanic/$repo_name.git"
                git remote set-url origin "git@github.com:kleinpanic/$repo_name.git" 2>/dev/null || true
            else
                log_msg "Repo #$repo_number: Remote 'origin' does not exist; adding remote."
                git remote add origin "git@github.com:kleinpanic/$repo_name.git" 2>/dev/null || true
            fi

            # Recheck if the remote now exists.
            if check_github_remote; then
                remote_available=true
                log_msg "Repo #$repo_number: GitHub remote now exists after setting URL."
            else
                log_msg "Repo #$repo_number: Remote still not available; attempting to create GitHub repo via gh."
                create_github_repo "$repo_name" "$repo_dir" "$repo_number"
                # Force-set the remote URL regardless.
                git remote set-url origin "git@github.com:kleinpanic/$repo_name.git" 2>/dev/null || true
                if check_github_remote; then
                    remote_available=true
                    log_msg "Repo #$repo_number: GitHub remote now exists after creation."
                else
                    log_msg "Repo #$repo_number: Failed to create or add a GitHub remote."
                fi
            fi
        else
            log_msg "Repo #$repo_number: No WiFi. Cannot add or create remote."
        fi
    else
        log_msg "Repo #$repo_number: Valid GitHub remote detected."
    fi

    # If no local changes exist, log and exit.
    if [ -z "$(git status --porcelain)" ]; then
        log_msg "Repo #$repo_number: No local changes detected."
        if [ "$remote_available" = false ]; then
            echo "Repo #$repo_number: NC-GDE" >> "$SMS_REPORT"
        else
            echo "Repo #$repo_number: NC-GE" >> "$SMS_REPORT"
        fi
        echo "NC-GE"
        return 0
    fi

    # Stage all changes.
    log_msg "Repo #$repo_number: Staging all changes."
    git add -A

    # Commit changes; override PGP signing for automation.
    if git -c commit.gpgSign=false commit -m "Automated update"; then
        log_msg "Repo #$repo_number: Local commit succeeded."
    else
        log_msg "Repo #$repo_number: Commit failed (perhaps nothing to commit)."
        echo "Repo #$repo_number: No commit" >> "$SMS_REPORT"
        return 0
    fi

    # Pull with rebase if a remote exists and WiFi is available.
    if [ "$remote_available" = true ] && check_wifi; then
        log_msg "Repo #$repo_number: Attempting pull --rebase on branch 'main'."
        if timeout 60s git pull --rebase --no-edit origin main; then
            log_msg "Repo #$repo_number: Rebase succeeded."
        else
            local pull_exit=$?
            log_msg "Repo #$repo_number: Rebase failed with exit code $pull_exit; aborting rebase."
            git rebase --abort || log_msg "Repo #$repo_number: Failed to abort rebase cleanly."
            echo "Repo #$repo_number: Rebase Conflict" >> "$SMS_REPORT"
            echo "MC"
            return 1
        fi
    else
        log_msg "Repo #$repo_number: Skipping pull/rebase (no remote or no internet)."
    fi

    # Push if a remote exists and WiFi is available.
    if [ "$remote_available" = true ] && check_wifi; then
        log_msg "Repo #$repo_number: Attempting push on branch 'main'."
        if timeout 60s git push origin main; then
            log_msg "Repo #$repo_number: Push succeeded."
            echo "Repo #$repo_number: P" >> "$SMS_REPORT"
            echo "P"
        else
            local push_output push_exit
            push_output=$(timeout 60s git push origin main 2>&1) || push_exit=$?
            log_msg "Repo #$repo_number: Push failed with exit code ${push_exit:-0} and output: $push_output"
            echo "Repo #$repo_number: PF" >> "$SMS_REPORT"
            # Fallback: Force-set the remote URL and try again.
            local repo_name
            repo_name=$(basename "$repo_dir")
            log_msg "Repo #$repo_number: Attempting fallback: setting remote URL to git@github.com:kleinpanic/$repo_name.git"
            git remote set-url origin "git@github.com:kleinpanic/$repo_name.git" 2>&1 || true
            local fallback_output fallback_exit
            fallback_output=$(timeout 60s git push origin main 2>&1) || fallback_exit=$?
            if [ "${fallback_exit:-0}" -eq 0 ]; then
                log_msg "Repo #$repo_number: Fallback push succeeded."
                echo "Repo #$repo_number: P" >> "$SMS_REPORT"
                echo "P"
            else
                log_msg "Repo #$repo_number: Fallback push failed with exit code ${fallback_exit:-0} and output: $fallback_output"
                echo "Repo #$repo_number: PF" >> "$SMS_REPORT"
                echo "PF"
                return 1
            fi
        fi
    else
        log_msg "Repo #$repo_number: No internet; changes committed locally."
        echo "Repo #$repo_number: LC" >> "$SMS_REPORT"
        echo "LC"
    fi

    return 0
}

# Start of the script
echo "Starting auto git update script on $(date)" > "$REPORT"
echo "(G-R), $(date)" > "$SMS_REPORT"

# Fetch valid repositories
repo_dirs=($(get_repo_dirs))

# Counters for SMS summary report
pushed_count=0
no_change_count=0
local_commit_count=0
conflict_count=0
error_count=0
created_count=0
no_github_repo_count=0
total_repos=${#repo_dirs[@]}

# Loop through each valid directory
repo_number=1
for repo_dir in "${repo_dirs[@]}"; do
    echo "Updating repository #$repo_number: $repo_dir"
    update_repo "$repo_dir" "$repo_number"
    case "$(tail -n 1 "$SMS_REPORT")" in
        *P) pushed_count=$((pushed_count + 1)) ;;
        *NC*) no_change_count=$((no_change_count + 1)) ;;
        *LC) local_commit_count=$((local_commit_count + 1)) ;;
        *MC) conflict_count=$((conflict_count + 1)) ;;
        *PF) error_count=$((error_count + 1)) ;;
        *lc-ngr*) no_github_repo_count=$((no_github_repo_count + 1)) ;;
        *GHS) created_count=$((created_count + 1)) ;;
    esac
    repo_number=$((repo_number + 1))
done

# Check if the detailed SMS report exceeds the SMS character limit
sms_detailed_content=$(cat "$SMS_REPORT")
if [ "${#sms_detailed_content}" -gt "$SMS_CHAR_LIMIT" ]; then
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo "Concat output activated"
    sms_summary="$DATE. Pushed: $pushed_count/$total_repos, No Change: $no_change_count/$total_repos, Locally Committed: $local_commit_count/$total_repos, Conflicts: $conflict_count/$total_repos, Errors: $error_count/$total_repos, No GitHub Repo: $no_github_repo_count/$total_repos, Created: $created_count/$total_repos"
    echo "$sms_summary" > "$SMS_REPORT"
fi

send_text() {
    /usr/bin/msmtp -a default -t <<EOF
To: $PHONE_NUMBER
From: $EMAIL
Subject: $SUBJECT

$(cat "$SMS_REPORT")
EOF
    return $?
}

copy_report_ssh() {
    # Ensure SSH_DIR is defined
    if [ -z "$SSH_DIR" ]; then
        echo "Error: SSH_DIR is not set. Please define it in your script."
        return 1
    fi
    
    # Create the remote directory if it doesn't exist
    ssh "$SSH_HOST" "mkdir -p $SSH_DIR"
    
    # Transfer the report file to the specified directory
    rsync -avz --progress "$REPORT" "$SSH_HOST:$SSH_DIR/"
    return $?
}

if check_wifi; then
    echo "WiFi is connected. Attempting to send text message and SSH transfer..."
    send_text && echo "Text message sent successfully." || echo "Failed to send text message."
    
    if copy_report_ssh; then
        echo "SSH transfer succeeded."
        rm -f "$REPORT"
    else
        echo "SSH transfer failed. Keeping local reports for troubleshooting."
    fi
else
    echo "No WiFi connection detected. Changes committed locally."
fi

update_repo_list() {
    local repo_list_file="$HOME/.config/setup/autogitupdate.txt"
    echo "Scanning for Git repositories..."
    # Adjust the search path as needed (e.g., $HOME or a specific projects directory)
    find "$HOME" -type d -name ".git" -prune | sed 's/\/.git$//' > "$repo_list_file"
    echo "Repository list updated at $repo_list_file"
}

if [[ "$1" == "--update-repos" ]]; then
    update_repo_list
    exit 0
fi
