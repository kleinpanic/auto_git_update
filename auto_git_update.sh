#!/usr/bin/env bash

# Check if required commands are available
for cmd in git nmcli msmtp ssh scp gh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$cmd is required but not installed. Exiting."
        exit 1
    fi
done

# Configuration
TXT_FILE="/home/klein/.config/setup/autogitupdate.txt"
PHONE_NUMBER="2673479614@vtext.com"  # Verizon SMS gateway
EMAIL="kleinpanic@gmail.com"
SUBJECT="G-U-R"
REPORT="/tmp/git_update_report.txt"  # Full detailed report
SMS_REPORT="/tmp/git_update_sms.txt"  # Minimal SMS summary
SSH_HOST="eulerpi5"  # Alias for the SSH connection
SSH_DIR="/home/klein/reports"  # Remote directory to store the report
SMS_CHAR_LIMIT=160  # Character limit for SMS messages

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
        [ -z "$repo_dir" ] && continue
        
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
    
    # Use GitHub CLI to create the repo
    if gh repo create "$repo_name" --public --source="$repo_dir" --remote=origin --push; then
        echo "Successfully created GitHub repository #$repo_number: $repo_name" >> "$REPORT"
        echo "Repo #$repo_number $repo_name: GHS (GitHub Repo Created Successfully)" >> "$SMS_REPORT"
        
        # Check if the repository has existing commits
        if [ -d "$repo_dir/.git" ] && [ "$(git -C "$repo_dir" rev-parse HEAD)" ]; then
            echo "Repository #$repo_number has existing commits. Attempting to add remote and push." >> "$REPORT"
            
            # Add the GitHub remote if not already added
            git remote add origin "git@github.com:kleinpanic/$repo_name.git" 2>/dev/null || true
            
            # Set the main branch if necessary
            git branch -M main
            
            # Push to GitHub
            if git push -u origin main; then
                echo "Existing repository #$repo_number pushed successfully to GitHub." >> "$REPORT"
                echo "Repo #$repo_number $repo_name: Pushed Successfully" >> "$SMS_REPORT"
            else
                echo "Failed to push the existing repository #$repo_number to GitHub." >> "$REPORT"
                echo "Repo #$repo_number $repo_name: Push Failed" >> "$SMS_REPORT"
            fi
        fi
        return 0
    else
        echo "Failed to create GitHub repository #$repo_number: $repo_name" >> "$REPORT"
        echo "Repo #$repo_number $repo_name: GCF (GitHub Repo Creation Failed)" >> "$SMS_REPORT"
        return 1
    fi
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

# Function to update, commit, and push the changes
update_repo() {
    local repo_dir="$1"
    local repo_number="$2"
    cd "$repo_dir" || return 1

    echo "Processing repository #$repo_number located at $repo_dir" >> "$REPORT"

    local github_exists=true
    if ! check_github_remote; then
        echo "No valid GitHub repository found for repo #$repo_number." >> "$REPORT"
        github_exists=false
        
        if check_wifi; then
            repo_name=$(basename "$repo_dir")
            create_github_repo "$repo_name" "$repo_dir" "$repo_number"
            github_exists=true
        fi
    fi

    if [ "$github_exists" = true ]; then
        git fetch origin &>/dev/null
        if ! git merge origin/main --no-commit --no-ff; then
            echo "Merge conflict detected in repo #$repo_number" >> "$REPORT"
            echo "Repo #$repo_number: MC" >> "$SMS_REPORT"
            git merge --abort
            return 1
        fi
    fi

    if git diff-index --quiet HEAD --; then
        echo "No changes detected in repo #$repo_number" >> "$REPORT"
        
        if [ "$github_exists" = false ]; then
            echo "Repo #$repo_number: NC-GDE" >> "$SMS_REPORT"
        else
            echo "Repo #$repo_number: NC-GE" >> "$SMS_REPORT"
        fi
        
        return 0
    fi

    git add -A
    git commit -m "Automated update"

    if [ "$github_exists" = false ]; then
        echo "No GitHub repository available for repo #$repo_number. Committing locally..." >> "$REPORT"
        echo "Repo #$repo_number: lc-ngr" >> "$SMS_REPORT"
        return 0
    fi

    if check_wifi; then
        echo "Internet is available. Attempting to push changes for repo #$repo_number..." >> "$REPORT"
        
        if ! git push origin main; then
            echo "Failed to push changes in repo #$repo_number" >> "$REPORT"
            echo "Repo #$repo_number: PF" >> "$SMS_REPORT"
            return 1
        else
            echo "Changes pushed successfully in repo #$repo_number" >> "$REPORT"
            echo "Repo #$repo_number: P" >> "$SMS_REPORT"
        fi
    else
        echo "No internet connection. Changes committed locally in repo #$repo_number" >> "$REPORT"
        echo "Repo #$repo_number: LC" >> "$SMS_REPORT"
    fi
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
    sms_summary="Pushed: $pushed_count/$total_repos, No Change: $no_change_count/$total_repos, Locally Committed: $local_commit_count/$total_repos, Conflicts: $conflict_count/$total_repos, Errors: $error_count/$total_repos, No GitHub Repo: $no_github_repo_count/$total_repos, Created: $created_count/$total_repos"
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
    ssh "$SSH_HOST" "mkdir -p $SSH_DIR"
    scp "$REPORT" "$SSH_HOST:$SSH_DIR/"
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
