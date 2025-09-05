# VPS Bandwidth Carry-Over Manager - Documentation
#
# Purpose
#   Interactive menu-driven Bash script to reset VPS bandwidth usage and optionally
#   carry over remaining bandwidth by adjusting per-VPS plan limits via the
#   Virtualizor admin API. Provides manual operations, configuration UI, and
#   automation via crontab entries.
#
# Key Features
#   - Interactive configuration (whiptail) for Virtualizor host/API credentials.
#   - Manual reset: reset all VPSes or a specific VPS by ID.
#   - Automation management: enable/disable daily, monthly, and "last day" cron jobs.
#   - Robust API interaction with curl and response validation via jq.
#   - Logging of run output and change summary to /tmp/reset_band.log and
#     /tmp/reset_band_changes.log.
#   - Error handling with trap to capture unexpected failures and print context.
#
# Usage
#   Interactive:
#     sudo /usr/bin/bash reset_band.sh
#     - Presents a whiptail menu: Configure Script, Manual Reset, Manage Automation.
#
#   Cron / Non-interactive:
#     /usr/bin/bash reset_band.sh --cron
#     - When run with --cron the script runs the reset logic for all VPSes once,
#       using stored configuration.
#
# Configuration file
#   Path: /etc/vps_manager.conf
#   Expected contents (shell variables):
#     HOST="your.virtualizor.ip.or.hostname"
#     KEY="admin_api_key"
#     PASS="admin_api_pass"
#   The script will create a default file if missing and prompts via whiptail.
#
# Dependencies
#   Required (checked at startup): whiptail, curl, jq
#   Also used (not explicitly checked): realpath, crontab, nano (for crontab editing)
#   Ensure these programs exist on the system where the script runs.
#
# Important files / variables
#   CONFIG_FILE   = /etc/vps_manager.conf
#   LOG_FILE      = /tmp/reset_band.log            # detailed run log
#   CHANGE_LOG    = /tmp/reset_band_changes.log    # human readable change summary
#   CRON_TAG      = "# vps-bandwidth-reset-cron"   # marker used to manage cron entries
#
# API endpoints used (built from CONFIG_FILE variables)
#   Base URL:
#     http://${HOST}:4084/index.php?adminapikey=${KEY}&adminapipass=${PASS}
#   Common calls:
#     - List / info:  &act=vs&api=json
#     - Reset usage:  &act=vs&bwreset=<vpsid>&api=json  (POST)
#     - Update plan:  &act=managevps&vpsid=<vpsid>&api=json  (POST with editvps=1, bandwidth, plid)
#
# Expected API JSON structure (for parsing with jq)
#   {
#     "vs": {
#       "<vpsid>": {
#         "bandwidth": <number>,        # plan limit in GB, 0 means unlimited
#         "used_bandwidth": <number>,   # used GB
#         "plid": <plan_id>,            # plan id to preserve when updating
#         ...
#       },
#       ...
#     }
#   }
#
# Core behavior (run_reset_logic)
#   - Mode "all": fetches all VPS entries and loops over each VPS ID.
#   - Mode "<vpsid>": validates VPS exists in API response and processes only it.
#   - For each VPS:
#     1. Read bandwidth (limit) and used_bandwidth from API response.
#     2. If limit == 0 (unlimited plan):
#          - Only reset usage via API (bwreset) and do not change plan bandwidth.
#     3. If limit > 0:
#          - Calculate new_limit = max(limit - used, 0) to carry over remaining quota.
#          - Call bwreset to zero usage and then call managevps (editvps) to set
#            the new bandwidth while preserving plid.
#     4. Validate each curl call succeeded (exit code) and HTTP code == 200.
#     5. Validate API JSON responses for expected fields (done, done.done, etc).
#     6. Append a human-readable line to CHANGE_LOG describing the change.
#
# Logging & Error Handling
#   - All informational and error messages are appended to LOG_FILE.
#   - The script traps ERR and runs error_handler which logs the exit code, line
#     number, and optionally prints the last 10 lines of the log for context.
#   - Interactive UI uses whiptail to show messages for success/failure and to
#     prompt/confirm destructive operations.
#
# Exit codes (not exhaustive; script may return different codes from functions)
#   0  - Success / no fatal errors
#   1  - Dependency check failure (missing programs)
#   2  - API/network/config load failure (e.g., curl failed or empty response)
#   3  - Response parse error when enumerating all VPS entries
#   4  - VPS-specific parse error or requested VPS not found
#   Non-zero (1) may also be returned if run_reset_logic encountered any per-VPS
#   errors (error_flag gets set).
#
# Automation (cron) management
#   - The automation menu manages crontab entries identified by CRON_TAG to
#     enable/disable scheduled runs.
#   - Preset options:
#       * Daily:   0 0 * * *   -> runs at 00:00
#       * Monthly: 0 2 1 * *   -> runs 1st of month at 02:00
#       * Last day workaround:
#           30 23 * * * [ "$(date +\%d -d tomorrow)" == "01" ] && /usr/bin/bash <script>
#         -> runs every day at 23:30 and only executes on the last day of month.
#   - The script uses realpath "$0" to insert the full script path into cron entries.
#
# Safety & Notes
#   - The script will modify VPS plan bandwidth values; use care and verify config.
#   - Test interactively with a single VPS ID before enabling automation for all.
#   - Ensure API credentials in /etc/vps_manager.conf have appropriate privileges.
#   - Because crontab edits and realpath are used, run as a user with expected crontab.
#   - Log files in /tmp are world-readable by default on many systems; secure them
#     if they contain sensitive info or rotate/clean them periodically.
#
# Typical workflow
#   1. Run interactively: configure HOST/KEY/PASS via "Configure Script".
#   2. Choose "Manual Reset" and test "Reset a SPECIFIC VPS" with a test VPS ID.
#   3. Inspect /tmp/reset_band.log and /tmp/reset_band_changes.log to validate.
#   4. When satisfied, enable daily/monthly automation via "Manage Automation".
#
# Implementation notes
#   - Uses jq for JSON parsing and curl for HTTP requests; API success is indicated
#     by JSON fields like "done" and "done.done" depending on endpoint.
#   - Uses whiptail for TUI dialogs; if running headless, use the --cron flag or
#     bypass interactive menus and run run_reset_logic directly.
#
# Author / Attribution
#   Script header indicates author: LivingGOD (embedded in UI prompt strings).
#
# Example /etc/vps_manager.conf
#   HOST="192.168.1.100"
#   KEY="your_api_key_here"
#   PASS="your_api_pass_here"
#
# End of documentation

#!/usr/bin/env bash
set -euo pipefail

# Trap for error reporting and cleanup
error_handler() {
    local exit_code=$?
    echo "$(date '+%F %T') [FATAL] Script exited with code $exit_code at line $LINENO" | tee -a "$LOG_FILE" >&2
    # Optionally print last 10 lines of log for context
    if [ -f "$LOG_FILE" ]; then
        echo "--- Last 10 log lines ---" >&2
        tail -n 10 "$LOG_FILE" >&2
    fi
    exit $exit_code
}
trap error_handler ERR

#================================================================
#
#          VPS Bandwidth Carry-Over Manager
#                      by LivingGOD
#
#   A menu-driven script to manually run or automate the
#   Virtualizor bandwidth carry-over process.
#
#================================================================


# --- Script Configuration ---
CONFIG_FILE="/etc/vps_manager.conf"
CRON_TAG="# vps-bandwidth-reset-cron"
LOG_FILE="/tmp/reset_band.log"
CHANGE_LOG="/tmp/reset_band_changes.log"

# --- Dependency Check ---
for dep in whiptail curl jq; do
    if ! command -v "$dep" &> /dev/null; then
        echo "Error: Command '$dep' is not installed. Please install it to continue." >&2
        exit 1
    fi
done

#================================================================
#   CONFIGURATION HANDLING
#================================================================
load_config() {
    # Load configuration from file, or create with defaults if it doesn't exist.
    if [ ! -f "$CONFIG_FILE" ]; then
        whiptail --title "First Time Setup" --msgbox "No configuration found. Creating default config file at $CONFIG_FILE. Please use the 'Configure' menu to set your API details." 10 78
        {
            echo "HOST=\"\""
            echo "KEY=\"\""
            echo "PASS=\"\""
        } > "$CONFIG_FILE"
    fi
    # shellcheck source=/dev/null
    if ! source "$CONFIG_FILE"; then
        echo "[ERROR] Failed to load configuration from $CONFIG_FILE" | tee -a "$LOG_FILE" >&2
        whiptail --title "Config Error" --msgbox "Failed to load configuration. Please check $CONFIG_FILE." 10 78
        exit 2
    fi
}

configure_script() {
    # UI for editing the configuration file.
    local current_host="$HOST"
    local current_key="$KEY"
    local current_pass="$PASS"

    # The `|| return 0` is to prevent `set -e` from exiting the script if the user cancels.
    local new_host new_key new_pass
    new_host=$(whiptail --title "Configure Host" --inputbox "Enter the Virtualizor Host IP:" 8 78 "$current_host" 3>&1 1>&2 2>&3) || return 0
    new_key=$(whiptail --title "Configure API Key" --inputbox "Enter the API Key:" 8 78 "$current_key" 3>&1 1>&2 2>&3) || return 0
    new_pass=$(whiptail --title "Configure API Pass" --inputbox "Enter the API Password:" 8 78 "$current_pass" 3>&1 1>&2 2>&3) || return 0

    {
        echo "HOST=\"$new_host\""
        echo "KEY=\"$new_key\""
        echo "PASS=\"$new_pass\""
    } > "$CONFIG_FILE"
    whiptail --title "Success" --msgbox "Configuration has been updated in $CONFIG_FILE." 8 78
}

#================================================================
#   CORE RESET LOGIC
#================================================================
run_reset_logic() {
        # Resets bandwidth for all or a specific VPS. Robust error handling and logging.
        local mode="$1"
        local error_flag=0

        log_info()  { echo "$(date '+%F %T') [INFO]  $*"  | tee -a "$LOG_FILE"; }
        log_error() { echo "$(date '+%F %T') [ERROR] $*" | tee -a "$LOG_FILE" >&2; error_flag=1; }

        local api_base="http://${HOST}:4084/index.php?adminapikey=${KEY}&adminapipass=${PASS}"

        log_info "Fetching server data..."
        local vs_json
        vs_json=$(curl -sS "${api_base}&act=vs&api=json")
        local curl_status=$?
        log_info "API response: $vs_json"
        if (( curl_status != 0 )); then
            log_error "API request failed (curl exit $curl_status). Check network and API credentials."
            whiptail --title "API Error" --msgbox "Failed to fetch server data. Check network and API credentials." 10 78
            return 2
        fi
        if [[ -z "$vs_json" ]]; then
            log_error "API returned empty response. Check API endpoint and credentials."
            whiptail --title "API Error" --msgbox "API returned empty response. Check API endpoint and credentials." 10 78
            return 2
        fi

        local vps_ids=()
        if [[ "$mode" == "all" ]]; then
            # Check if the response has the expected structure
            if ! echo "$vs_json" | jq -e '.vs' >/dev/null 2>&1; then
                log_error "API response missing 'vs' field. Response: $vs_json"
                whiptail --title "Parse Error" --msgbox "API response missing 'vs' field. Check API endpoint and credentials." 10 78
                return 3
            fi
            
            # Check if there are any VPS entries
            local vps_count
            vps_count=$(echo "$vs_json" | jq -r '.vs | length')
            if [[ "$vps_count" -eq 0 ]]; then
                log_info "No VPS entries found in API response."
            else
                log_info "Found $vps_count VPS entries in API response."
            fi
            
            if ! mapfile -t vps_ids < <(echo "$vs_json" | jq -r '.vs | keys_unsorted[]' 2>/dev/null); then
                log_error "Failed to parse VPS IDs from API response."
                whiptail --title "Parse Error" --msgbox "Failed to parse VPS IDs from API response." 10 78
                return 3
            fi
        else
            # Check if the response has the expected structure for specific VPS
            if ! echo "$vs_json" | jq -e '.vs' >/dev/null 2>&1; then
                log_error "API response missing 'vs' field. Response: $vs_json"
                whiptail --title "Parse Error" --msgbox "API response missing 'vs' field. Check API endpoint and credentials." 10 78
                return 4
            fi
            
            if ! echo "$vs_json" | jq -e --arg vpsid "$mode" '.vs[$vpsid]' > /dev/null; then
                log_error "VPS ID $mode not found in API response."
                whiptail --title "VPS Not Found" --msgbox "VPS ID $mode not found in API response." 10 78
                return 4
            fi
            vps_ids=("$mode")
        fi
        log_info "Target VPS IDs: ${vps_ids[*]}"

        if [ ${#vps_ids[@]} -eq 0 ]; then
            log_info "No target VPSs found. Exiting."
            whiptail --title "No VPS Found" --msgbox "No target VPSs found. Exiting." 10 78
            return 0
        fi

        for vpsid in "${vps_ids[@]}"; do
            log_info "─ VPS $vpsid"

            local limit_str
            limit_str=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].bandwidth // 0')
            if [[ -z "$limit_str" ]]; then
                log_error "Failed to get bandwidth limit for VPS $vpsid."
                whiptail --title "Parse Error" --msgbox "Failed to get bandwidth limit for VPS $vpsid." 10 78
                continue
            fi
            local limit
            limit=$(echo "$limit_str" | awk '{printf "%d", $1}')

            if (( limit==0 )); then
                log_info "$vpsid → unlimited plan. Resetting usage only."
                local reset
                reset=$(curl -sS -X POST -w '\nHTTP_CODE:%{http_code}' "${api_base}&act=vs&bwreset=${vpsid}&api=json")
                local curl_reset_status=$?
                if (( curl_reset_status != 0 )); then
                    log_error "$vpsid → curl failed with exit code $curl_reset_status"
                    whiptail --title "Reset Error" --msgbox "$vpsid → curl failed with exit code $curl_reset_status" 10 78
                    continue
                fi
                local r_body=${reset%$'\n'HTTP_CODE:*}; local r_code=${reset##*HTTP_CODE:}
                if [[ "$r_code" != "200" ]]; then
                    log_error "$vpsid → usage reset failed (HTTP $r_code) body: $r_body"
                    whiptail --title "Reset Error" --msgbox "$vpsid → usage reset failed (HTTP $r_code)" 10 78
                    continue
                fi
                if ! echo "$r_body" | jq -e '.done //0' >/dev/null 2>&1; then
                    log_error "$vpsid → API response missing 'done' field. Response: $r_body"
                    whiptail --title "Reset Error" --msgbox "$vpsid → API response format error" 10 78
                    continue
                fi
                if [[ $(echo "$r_body" | jq -r '.done //0') -ne 1 ]]; then
                    log_error "$vpsid → usage reset failed (done != 1) body: $r_body"
                    whiptail --title "Reset Error" --msgbox "$vpsid → usage reset failed (done != 1)" 10 78
                    continue
                fi
                log_info "$vpsid → usage reset OK"
                continue
            fi

            local used_str
            used_str=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].used_bandwidth // 0')
            if [[ -z "$used_str" ]]; then
                log_error "Failed to get used bandwidth for VPS $vpsid."
                whiptail --title "Parse Error" --msgbox "Failed to get used bandwidth for VPS $vpsid." 10 78
                continue
            fi
            local used
            used=$(echo "$used_str" | awk '{printf "%d", $1}')
            local plid
            plid=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].plid // 0')

            local new_limit=$(( limit - used )); (( new_limit < 0 )) && new_limit=0
            log_info "$vpsid : ${used}/${limit} GB → 0/${new_limit} GB"

            local reset
            reset=$(curl -sS -X POST -w '\nHTTP_CODE:%{http_code}' "${api_base}&act=vs&bwreset=${vpsid}&api=json")
            local curl_reset_status=$?
            if (( curl_reset_status != 0 )); then
                log_error "$vpsid → curl failed with exit code $curl_reset_status"
                whiptail --title "Reset Error" --msgbox "$vpsid → curl failed with exit code $curl_reset_status" 10 78
                continue
            fi
            local r_body=${reset%$'\n'HTTP_CODE:*}; local r_code=${reset##*HTTP_CODE:}
            if [[ "$r_code" != "200" ]]; then
                log_error "$vpsid → reset failed (HTTP $r_code) body: $r_body"
                whiptail --title "Reset Error" --msgbox "$vpsid → reset failed (HTTP $r_code)" 10 78
                continue
            fi
            if ! echo "$r_body" | jq -e '.done //0' >/dev/null 2>&1; then
                log_error "$vpsid → API response missing 'done' field. Response: $r_body"
                whiptail --title "Reset Error" --msgbox "$vpsid → API response format error" 10 78
                continue
            fi
            if [[ $(echo "$r_body" | jq -r '.done //0') -ne 1 ]]; then
                log_error "$vpsid → reset failed (done != 1) body: $r_body"
                whiptail --title "Reset Error" --msgbox "$vpsid → reset failed (done != 1)" 10 78
                continue
            fi
            log_info "Usage reset OK"

            local update
            update=$(curl -sS -w '\nHTTP_CODE:%{http_code}' -d "editvps=1" -d "bandwidth=$new_limit" -d "plid=${plid}" "${api_base}&act=managevps&vpsid=${vpsid}&api=json")
            local curl_update_status=$?
            if (( curl_update_status != 0 )); then
                log_error "$vpsid → update curl failed with exit code $curl_update_status"
                whiptail --title "Update Error" --msgbox "$vpsid → update curl failed with exit code $curl_update_status" 10 78
                continue
            fi
            local u_body=${update%$'\n'HTTP_CODE:*}; local u_code=${update##*HTTP_CODE:}
            if [[ "$u_code" != "200" ]]; then
                log_error "$vpsid → update failed (HTTP $u_code) body: $u_body"
                whiptail --title "Update Error" --msgbox "$vpsid → update failed (HTTP $u_code)" 10 78
                continue
            fi
            if ! echo "$u_body" | jq -e '.done' >/dev/null 2>&1; then
                log_error "$vpsid → update API response missing 'done' field. Response: $u_body"
                whiptail --title "Update Error" --msgbox "$vpsid → update API response format error" 10 78
                continue
            fi
            if ! echo "$u_body" | jq -e '.done.done' >/dev/null 2>&1; then
                log_error "$vpsid → update API response missing 'done.done' field. Response: $u_body"
                whiptail --title "Update Error" --msgbox "$vpsid → update API response format error" 10 78
                continue
            fi
            if [[ $(echo "$u_body" | jq -r '.done.done //false') != true ]]; then
                log_error "$vpsid → update failed (done.done != true) body: $u_body"
                whiptail --title "Update Error" --msgbox "$vpsid → update failed (done.done != true)" 10 78
                continue
            fi
            log_info "Limit updated (plan $plid preserved)"
            printf "%(%F %T)T  VPS %s  %d/%d => 0/%d (plan %d)\n" -1 "$vpsid" "$used" "$limit" "$new_limit" "$plid" >>"$CHANGE_LOG"
        done
        log_info "=== Completed ==="
        return $error_flag
}

#================================================================
#   UI & MENU FUNCTIONS
#================================================================
manual_reset_menu() {
    local choice
    choice=$(whiptail --title "Manual Bandwidth Reset" --menu "Choose an option" 15 60 2 \
        "1" "Reset ALL VPSs" \
        "2" "Reset a SPECIFIC VPS" 3>&1 1>&2 2>&3) || return 0

    case "$choice" in
        1)
            whiptail --title "Confirm Reset All" --yesno "Are you sure you want to reset bandwidth for ALL servers?" 8 78
            if [ $? -eq 0 ]; then
                # Clear log file for a clean view of this run
                > "$LOG_FILE"
                whiptail --infobox "Processing all servers, please wait..." 8 78
                local title
                if run_reset_logic "all"; then
                    title="Success"
                else
                    title="Failed"
                fi
                whiptail --title "$title" --textbox "$LOG_FILE" 20 78 --scrolltext
            fi
            ;;
        2)
            local vps_id
            vps_id=$(whiptail --title "Specific VPS Reset" --inputbox "Enter the VPS ID to reset:" 8 78 3>&1 1>&2 2>&3) || return 0
            if [ -n "$vps_id" ]; then
                # Clear log file for a clean view of this run
                > "$LOG_FILE"
                whiptail --infobox "Processing VPS $vps_id, please wait..." 8 78
                local title
                if run_reset_logic "$vps_id"; then
                    title="Success"
                else
                    title="Failed"
                fi
                whiptail --title "$title" --textbox "$LOG_FILE" 20 78 --scrolltext
            fi
            ;;
    esac
}

automation_menu() {
    local choice
    choice=$(whiptail --title "Automation Management" --menu "Manage automated cron jobs" 19 78 6 \
        "1" "Enable DAILY Reset (00:00)" \
        "2" "Enable MONTHLY Reset (1st of month at 02:00)" \
        "3" "Enable LAST DAY Monthly Reset (23:30)" \
        "4" "DISABLE Automation" \
        "5" "View Status" \
        "6" "Manually Edit Crontab (nano)" 3>&1 1>&2 2>&3) || return 0

    # Get the full, absolute path to the currently running script
    local script_full_path
    script_full_path=$(realpath "$0")

    case "$choice" in   
        1)
            local current_cron clean_cron
            current_cron=$(crontab -l 2>/dev/null || true)
            clean_cron=$(echo "$current_cron" | grep -vF "$CRON_TAG" || true)
            printf "%s\n%s\n" "$clean_cron" "0 0 * * * /usr/bin/bash $script_full_path --cron $CRON_TAG" | sed '/^$/d' | crontab -
            whiptail --title "Success" --msgbox "Daily cron job enabled." 8 78
            ;;
        2)
            local current_cron clean_cron
            current_cron=$(crontab -l 2>/dev/null || true)
            clean_cron=$(echo "$current_cron" | grep -vF "$CRON_TAG" || true)
            printf "%s\n%s\n" "$clean_cron" "0 2 1 * * /usr/bin/bash $script_full_path --cron $CRON_TAG" | sed '/^$/d' | crontab -
            whiptail --title "Success" --msgbox "Monthly cron job enabled." 8 78
            ;;
        3)
            local current_cron clean_cron
            current_cron=$(crontab -l 2>/dev/null || true)
            clean_cron=$(echo "$current_cron" | grep -vF "$CRON_TAG" || true)
            # Last day of month at 23:30 workaround
            local last_day_cron="30 23 * * * [ \"\$(date +\\%d -d tomorrow)\" == \"01\" ] && /usr/bin/bash $script_full_path --cron $CRON_TAG"
            printf "%s\n%s\n" "$clean_cron" "$last_day_cron" | sed '/^$/d' | crontab -
            whiptail --title "Success" --msgbox "Last day of month cron job enabled (23:30)." 8 78
            ;;
        4)
            (crontab -l 2>/dev/null || true) | grep -vF "$CRON_TAG" | crontab -
            whiptail --title "Success" --msgbox "All automation has been disabled." 8 78
            ;;
        5)
            local status
            status=$(crontab -l 2>/dev/null | grep "$CRON_TAG" || echo "Automation is currently disabled.")
            whiptail --title "Automation Status" --msgbox "$status" 8 78
            ;;
        6)
            EDITOR=nano crontab -e
            whiptail --title "Crontab" --msgbox "Crontab editing session finished." 8 78
            ;;
    esac
}

#================================================================
#   MAIN SCRIPT EXECUTION
#================================================================

# Handle non-interactive cron execution
if [[ "${1:-}" == "--cron" ]]; then
    load_config
    run_reset_logic "all"
    exit 0
fi

# Load config for interactive session
load_config

# Main interactive menu loop
while true; do
    choice=$(whiptail --title "VPS Bandwidth Manager by LivingGOD" --menu "Select an option" 16 60 4 \
        "1" "Configure Script" \
        "2" "Manual Reset" \
        "3" "Manage Automation" \
        "4" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
        1)
            configure_script
            # After configuring, reload the variables
            load_config
            ;;
        2)
            manual_reset_menu
            ;;
        3)
            automation_menu
            ;;
        4)
            exit 0
            ;;
        *)
            # This case handles 'Cancel' on the main menu
            exit 0
            ;;
    esac
done

