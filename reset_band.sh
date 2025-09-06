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
#   Diagnostic commands:
#     /usr/bin/bash reset_band.sh --list-vps
#     - Lists all VPS IDs in the system (useful for finding valid VPS IDs)
#     /usr/bin/bash reset_band.sh --list-vps-preview  
#     - Shows first 20 VPS IDs for quick preview
#     /usr/bin/bash reset_band.sh --check-vps <VPS_ID>
#     - Checks if a specific VPS ID exists and shows its status
#
# Configuration file
#   Path: /etc/vps_manager.conf
#   Expected contents (shell variables):
#     HOST="your.virtualizor.master.ip.or.hostname"
#     KEY="admin_api_key"
#     PASS="admin_api_pass"
#   Note: HOST should be the master server IP/hostname, and the API calls use port 4085.
#   The script will create a default file if missing and prompts via whiptail.
#
# Dependencies
#   Required (checked at startup): whiptail, curl, jq
#   Also used (not explicitly checked): realpath, crontab, nano (for crontab editing)
#   Ensure these programs exist on the system where the script runs.
#
# Important files / variables
#   CONFIG_FILE   = /etc/vps_manager.conf
#   DIAG_DIR      = /root                          # directory for diagnostic logs
#   LOG_FILE      = /root/reset_band.log           # detailed run log
#   CHANGE_LOG    = /root/reset_band_changes.log   # human readable change summary
#   CRON_TAG      = "# vps-bandwidth-reset-cron"   # marker used to manage cron entries
#
# API endpoints used (built from CONFIG_FILE variables)
#   Base URL:
#     https://${HOST}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}
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
#   HOST="192.168.1.100"  # Master server IP
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
# Directory to write diagnostic and run logs. Set to /root per request.
DIAG_DIR="/root"
LOG_FILE="${DIAG_DIR}/reset_band.log"
CHANGE_LOG="${DIAG_DIR}/reset_band_changes.log"

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
            echo "# Optional: full API base URL override (including scheme, host, port and index.php query string)
# Example: API_BASE=\"https://MASTER_IP:4085/index.php?adminapikey=KEY&adminapipass=PASS\"
API_BASE=\"\""
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
        local diagnose_mode=0
        if [[ "${2:-}" == "--diagnose" ]]; then
            diagnose_mode=1
        fi

        log_info()  { echo "$(date '+%F %T') [INFO]  $*"  | tee -a "$LOG_FILE"; }
        log_error() { echo "$(date '+%F %T') [ERROR] $*" | tee -a "$LOG_FILE" >&2; error_flag=1; }

        # Normalize HOST: strip scheme and trailing slash so user may set HOST with or without http(s)://
        local host_clean
        host_clean="${HOST#http://}"
        host_clean="${host_clean#https://}"
        host_clean="${host_clean%%/}"

        # If API_BASE override is set in config, use it. Otherwise build from HOST.
        local api_base
        if [[ -n "${API_BASE:-}" ]]; then
            api_base="$API_BASE"
            log_info "Using API_BASE override from config."
        else
            # If HOST already contains a port (host:port) use it, otherwise default to master port 4085
            if [[ "$host_clean" == *:* ]]; then
                api_base="https://${host_clean}/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
            else
                api_base="https://${host_clean}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
            fi
        fi
        if [[ "$HOST" != "$host_clean" ]]; then
            log_info "Normalized HOST from '$HOST' to '$host_clean'"
        fi

    log_info "Fetching server data..."
    # First try a single request asking for all records using documented 'reslen=0'
    # Virtualizor docs: reslen = number of records to be returned (default 50), page = page number
    local api_url="${api_base}&act=vs&api=json&reslen=0"
    log_info "Attempting API URL (reslen=0 -> all records): $api_url"
        local vs_json
        if (( diagnose_mode == 1 )); then
            log_info "Running in diagnose mode: saving verbose curl output to ${DIAG_DIR}/reset_band_curl_verbose.log"
            mkdir -p "${DIAG_DIR}" 2>/dev/null || true
            curl -sS -L --max-redirs 5 -D "${DIAG_DIR}/reset_band_curl_headers.log" -o "${DIAG_DIR}/reset_band_curl_body.log" --trace-ascii "${DIAG_DIR}/reset_band_curl_verbose.log" "$api_url" || true
            if [ -f "${DIAG_DIR}/reset_band_curl_body.log" ]; then
                vs_json=$(cat "${DIAG_DIR}/reset_band_curl_body.log")
            else
                vs_json=""
            fi
            local curl_status=0
        else
            vs_json=$(curl -sS -L --max-redirs 5 "$api_url")
            local curl_status=$?
        fi
        log_info "API response (initial fetch): $(echo "$vs_json" | head -c 1024)"
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
        if echo "$vs_json" | grep -qi '<html\|<script'; then
            log_error "API response appears to be HTML (possible redirect or proxy). Response: $vs_json"
            whiptail --title "API Error" --msgbox "API returned HTML (redirect/proxy). Verify HOST, protocol (https) and that the master API is reachable." 12 78
            return 2
        fi

        local vps_ids=()
        if [[ "$mode" == "all" ]]; then
            # Check if the response has the expected structure
            if ! echo "$vs_json" | jq -e '.vs' >/dev/null 2>&1; then
                if echo "$vs_json" | jq -e '.1' >/dev/null 2>&1; then
                    log_error "API response appears to be for servers, not VPSes. Ensure HOST is set to the master server IP. Response: $vs_json"
                    whiptail --title "API Error" --msgbox "API response is for servers, not VPSes. Check that HOST is the master server IP." 10 78
                else
                    log_error "API response missing 'vs' field. Response: $vs_json"
                    whiptail --title "Parse Error" --msgbox "API response missing 'vs' field. Check API endpoint and credentials." 10 78
                fi
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
            
            # If we got a small, likely-truncated result (common default = 50), try robust paging
            # Try both common page indexing schemes (0-based and 1-based) and pick the best result.
            if [[ "$vps_count" -le 50 ]]; then
                log_info "API returned $vps_count entries; attempting paged requests (reslen/page) to collect all VPSs."
                local per=50
                local best_count=$vps_count
                local best_json="$vs_json"
                for start_page in 0 1; do
                    # Clean candidate temp pages
                    rm -f "${DIAG_DIR}/reset_band_page_candidate_${start_page}_*.json" 2>/dev/null || true
                    local page=$start_page
                    while true; do
                        local page_url="${api_base}&act=vs&api=json&reslen=${per}&page=${page}"
                        log_info "Fetching candidate start=${start_page} page=${page} -> $page_url"
                        if (( diagnose_mode == 1 )); then
                            curl -sS -L --max-redirs 5 -o "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" "$page_url" || true
                        else
                            curl -sS -L --max-redirs 5 -o "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" "$page_url"
                        fi
                        if ! jq -e '.vs' "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" >/dev/null 2>&1; then
                            log_info "  candidate start=${start_page} page=${page}: no 'vs' field (stopping)"
                            rm -f "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" 2>/dev/null || true
                            break
                        fi
                        local page_count
                        page_count=$(jq -r '.vs | length' "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" 2>/dev/null || echo 0)
                        log_info "  candidate start=${start_page} page=${page}: $page_count entries"
                        if [[ "$page_count" -eq 0 ]]; then
                            break
                        fi
                        page=$((page+1))
                    done

                    # Merge candidate pages if any
                    shopt -s nullglob
                    candidate_files=("${DIAG_DIR}"/reset_band_page_candidate_${start_page}_*.json)
                    shopt -u nullglob
                    if (( ${#candidate_files[@]} )); then
                        # Try batch merge with normalization
                        local candidate_json
                        candidate_json=$(jq -s 'map(.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } elif has("vps_id") then { ( (.vps_id|tostring) ): . } else {} end ) | add) else . end) | add | {vs: .}' "${candidate_files[@]}" 2>/dev/null || echo '{}')
                        candidate_count=$(echo "$candidate_json" | jq -r '.vs | length' 2>/dev/null || echo 0)
                        log_info "Candidate start=${start_page}: merged ${candidate_count} total VPS entries"
                        # Save candidate merged JSON
                        echo "$candidate_json" > "${DIAG_DIR}/reset_band_candidate_${start_page}_merged.json" 2>/dev/null || true
                        # Clean candidate pages
                        rm -f "${DIAG_DIR}/reset_band_page_candidate_${start_page}_*.json" 2>/dev/null || true
                        if [[ $candidate_count -gt $best_count ]]; then
                            best_count=$candidate_count
                            best_json="$candidate_json"
                            log_info "New best candidate: start=${start_page} with ${candidate_count} entries"
                        fi
                    else
                        log_info "Candidate start=${start_page}: no pages saved, count=0"
                    fi
                done
                # Use best result
                vs_json="$best_json"
                vps_count=$best_count
                # Save merged JSON for inspection
                echo "$vs_json" > "${DIAG_DIR}/reset_band_merged_vs.json" 2>/dev/null || true
                log_info "Saved merged VS JSON to ${DIAG_DIR}/reset_band_merged_vs.json (size=$(stat -c%s \"${DIAG_DIR}/reset_band_merged_vs.json\" 2>/dev/null || echo '?') bytes)"
                log_info "Merged .vs type: $(echo "$vs_json" | jq -r '.vs | type' 2>/dev/null || echo 'unknown')"
            fi

            if ! mapfile -t vps_ids < <(echo "$vs_json" | jq -r '.vs | keys_unsorted[]' 2>/dev/null); then
                log_error "Failed to parse VPS IDs from API response."
                whiptail --title "Parse Error" --msgbox "Failed to parse VPS IDs from API response." 10 78
                return 3
            fi
        else
            # Check if the response has the expected structure for specific VPS
            if ! echo "$vs_json" | jq -e '.vs' >/dev/null 2>&1; then
                if echo "$vs_json" | jq -e '.1' >/dev/null 2>&1; then
                    log_error "API response appears to be for servers, not VPSes. Ensure HOST is set to the master server IP. Response: $vs_json"
                    whiptail --title "API Error" --msgbox "API response is for servers, not VPSes. Check that HOST is the master server IP." 10 78
                else
                    log_error "API response missing 'vs' field. Response: $vs_json"
                    whiptail --title "Parse Error" --msgbox "API response missing 'vs' field. Check API endpoint and credentials." 10 78
                fi
                return 4
            fi
            
            # Added paging for specific VPS mode to handle VPSes beyond the first 50
            if ! echo "$vs_json" | jq -e --arg vpsid "$mode" '.vs[$vpsid]' > /dev/null; then
                # VPS not found in initial response, try paging if needed
                vps_count=$(echo "$vs_json" | jq -r '.vs | length')
                if [[ "$vps_count" -le 50 ]]; then
                    log_info "VPS $mode not in initial response; attempting paged requests to find it."
                    # Clean up any previous temp pages
                    rm -f "${DIAG_DIR}/reset_band_page_*.json" 2>/dev/null || true
                    local per=50
                    local page=0
                    while true; do
                        local page_url="${api_base}&act=vs&api=json&reslen=${per}&page=${page}"
                        log_info "Fetching page $page for VPS $mode"
                        if (( diagnose_mode == 1 )); then
                            curl -sS -L --max-redirs 5 -o "${DIAG_DIR}/reset_band_page_${page}.json" "$page_url" || true
                        else
                            curl -sS -L --max-redirs 5 -o "${DIAG_DIR}/reset_band_page_${page}.json" "$page_url"
                        fi
                        # Debug: confirm file was created
                        if [[ -f "${DIAG_DIR}/reset_band_page_${page}.json" ]]; then
                            log_info "File created: ${DIAG_DIR}/reset_band_page_${page}.json (size=$(stat -c%s \"${DIAG_DIR}/reset_band_page_${page}.json\" 2>/dev/null || echo '?'))"
                        else
                            log_info "ERROR: Failed to create ${DIAG_DIR}/reset_band_page_${page}.json"
                        fi
                        # Validate page
                        if ! jq -e '.vs' "${DIAG_DIR}/reset_band_page_${page}.json" >/dev/null 2>&1; then
                            log_info "Page $page did not contain 'vs' field; stopping pagination."
                            break
                        fi
                        local page_count
                        page_count=$(jq -r '.vs | length' "${DIAG_DIR}/reset_band_page_${page}.json")
                        log_info "Page $page contains $page_count entries."
                        # If no entries, stop
                        if [[ "$page_count" -eq 0 ]]; then
                            break
                        fi
                        page=$((page+1))
                    done
                    # Merge pages into one JSON object
                    log_info "Checking for page files in ${DIAG_DIR}..."
                    # Use nullglob to safely expand the glob into an array; quoted globs won't expand
                    shopt -s nullglob
                    page_files=("${DIAG_DIR}"/reset_band_page_*.json)
                    shopt -u nullglob
                    if (( ${#page_files[@]} )); then
                        log_info "Found ${#page_files[@]} page files: ${page_files[*]}"
                        # Robust merge: convert any array-shaped .vs into an object keyed by vps id
                        vs_json=$(jq -s 'map(.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } elif has("vps_id") then { ( (.vps_id|tostring) ): . } else {} end ) | add) else . end) | add | {vs: .}' "${page_files[@]}" 2>/dev/null || echo '{}')
                        # Clean temp pages
                        rm -f "${DIAG_DIR}"/reset_band_page_*.json 2>/dev/null || true
                        vps_count=$(echo "$vs_json" | jq -r '.vs | length' 2>/dev/null || echo 0)
                        log_info "After paging, total VPS entries: $vps_count"
                        # Save merged JSON for inspection
                        echo "$vs_json" > "${DIAG_DIR}/reset_band_merged_vs.json" 2>/dev/null || true
                        log_info "Saved merged VS JSON to ${DIAG_DIR}/reset_band_merged_vs.json (size=$(stat -c%s \"${DIAG_DIR}/reset_band_merged_vs.json\" 2>/dev/null || echo '?') bytes)"
                        log_info "Merged .vs type: $(echo "$vs_json" | jq -r '.vs | type' 2>/dev/null || echo 'unknown')"
                    else
                        log_info "No page files found - merge skipped"
                    fi
                fi
                # Check again after paging
                if ! echo "$vs_json" | jq -e --arg vpsid "$mode" '.vs[$vpsid]' > /dev/null; then
                    log_info "VPS $mode not found in normal listing. Checking suspended VPSes..."
                    
                    # Try searching for suspended VPSes specifically
                    local suspended_url="${api_base}&act=vs&api=json&vsstatus=s&reslen=0"
                    log_info "Checking suspended VPSes: $suspended_url"
                    local suspended_json
                    if (( diagnose_mode == 1 )); then
                        suspended_json=$(curl -sS -L --max-redirs 5 "$suspended_url" || echo '{}')
                    else
                        suspended_json=$(curl -sS -L --max-redirs 5 "$suspended_url")
                    fi
                    
                    if echo "$suspended_json" | jq -e --arg vpsid "$mode" '.vs[$vpsid]' > /dev/null 2>&1; then
                        log_info "VPS $mode found in suspended VPSes list."
                        vs_json="$suspended_json"
                        local vps_status="suspended"
                        local vps_suspend_reason=$(echo "$vs_json" | jq -r --arg vpsid "$mode" '.vs[$vpsid].suspend_reason // "Unknown"')
                        log_info "VPS $mode is SUSPENDED. Reason: $vps_suspend_reason"
                        log_info "Proceeding with suspended VPS $mode (no interactive prompt)."
                    else
                        log_info "VPS $mode not found in suspended VPSes either. Checking unsuspended VPSes..."
                        
                        # Try searching for unsuspended VPSes specifically  
                        local unsuspended_url="${api_base}&act=vs&api=json&vsstatus=u&reslen=0"
                        log_info "Checking unsuspended VPSes: $unsuspended_url"
                        local unsuspended_json
                        if (( diagnose_mode == 1 )); then
                            unsuspended_json=$(curl -sS -L --max-redirs 5 "$unsuspended_url" || echo '{}')
                        else
                            unsuspended_json=$(curl -sS -L --max-redirs 5 "$unsuspended_url")
                        fi
                        
                        if echo "$unsuspended_json" | jq -e --arg vpsid "$mode" '.vs[$vpsid]' > /dev/null 2>&1; then
                            log_info "VPS $mode found in unsuspended VPSes list."
                            vs_json="$unsuspended_json"
                        else
                            log_error "VPS ID $mode not found in any API response (normal, suspended, or unsuspended)."
                            whiptail --title "VPS Not Found" --msgbox "VPS ID $mode not found in any API response.\n\nChecked:\n- Normal listing\n- Suspended VPSes\n- Unsuspended VPSes\n\nVPS may not exist or may be in an unusual state." 14 78
                            return 4
                        fi
                    fi
                fi
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

            # Calculate new plan bandwidth
            # For regular (non-negative) plans: reduce limit by used, but not below 0
            # For negative plans (special cases): increase the negative allowance by adding used
            local new_limit
            if (( limit < 0 )); then
                # Negative plan: move towards zero by adding used to the negative limit
                new_limit=$(( limit + used ))
            else
                # Regular plan: subtract used; allow negative remainder when usage > limit
                new_limit=$(( limit - used ))
            fi
            # For logging, show the new plan value which may be negative
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

# List available VPS IDs: non-interactive command to show all VPS IDs
if [[ "${1:-}" == "--list-vps" ]]; then
    load_config
    echo "Listing all available VPS IDs..."
    # Build api_base same as run_reset_logic
    host_clean="${HOST#http://}"
    host_clean="${host_clean#https://}"
    host_clean="${host_clean%%/}"
    if [[ -n "${API_BASE:-}" ]]; then
        api_base="$API_BASE"
    else
        if [[ "$host_clean" == *:* ]]; then
            api_base="https://${host_clean}/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
        else
            api_base="https://${host_clean}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
        fi
    fi
    
    # Get all VPS IDs using the same pagination logic as run_reset_logic
    api_url="${api_base}&act=vs&api=json&reslen=0"
    vs_json=$(curl -sS -L --max-redirs 5 "$api_url" 2>/dev/null || echo '{}')

    if echo "$vs_json" | jq -e '.vs' >/dev/null 2>&1; then
        vps_count=$(echo "$vs_json" | jq -r '.vs | length')

        # If we got a small, likely-truncated result (common default = 50), try paging
        if [[ "$vps_count" -le 50 ]]; then
            echo "Fetching all VPS IDs using pagination..."
            per=50
            best_count=$vps_count
            best_json="$vs_json"
            # Try both common page indexing schemes (0-based and 1-based) and pick the best result
            for start_page in 0 1; do
                # Clean candidate temp pages
                rm -f "${DIAG_DIR}/reset_band_page_candidate_${start_page}_*.json" 2>/dev/null || true
                page=$start_page
                while true; do
                        page_url="${api_base}&act=vs&api=json&reslen=${per}&page=${page}"
                        echo "Fetching candidate start=${start_page} page=${page} -> $page_url"
                        curl -sS -L --max-redirs 5 -o "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" "$page_url" 2>/dev/null
                        if ! jq -e '.vs' "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" >/dev/null 2>&1; then
                            echo "  candidate start=${start_page} page=${page}: no 'vs' field (stopping)"
                            rm -f "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" 2>/dev/null || true
                            break
                        fi
                        page_count=$(jq -r '.vs | length' "${DIAG_DIR}/reset_band_page_candidate_${start_page}_${page}.json" 2>/dev/null || echo 0)
                        echo "  candidate start=${start_page} page=${page}: $page_count entries"
                        if [[ "$page_count" -eq 0 ]]; then
                            break
                        fi
                        page=$((page+1))
                done

                # Merge candidate pages if any (use array globbing to avoid quoted-glob issues)
                shopt -s nullglob
                candidate_files=("${DIAG_DIR}"/reset_band_page_candidate_${start_page}_*.json)
                shopt -u nullglob
                if (( ${#candidate_files[@]} )); then
                    echo "  Candidate files: ${candidate_files[*]}"
                    # Print short preview of each file to help debugging if jq fails
                    for cf in "${candidate_files[@]}"; do
                        echo "    -> ${cf}: size=$(stat -c%s "${cf}" 2>/dev/null || echo '?') bytes"
                        # show first 160 chars of file for quick inspection
                        head -c 160 "${cf}" | sed -n '1p' | sed 's/$/\n/' | sed 's/\n/\n    /g' || true
                    done

                    # Try to merge all pages at once. Capture jq exit status so set -e doesn't abort.
                    candidate_json=$(jq -s 'map(.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } elif has("vps_id") then { ( (.vps_id|tostring) ): . } else {} end ) | add) else . end) | add | {vs: .}' "${candidate_files[@]}" 2>"${DIAG_DIR}/reset_band_jq_error.log" ) || true
                    jq_exit=$?
                    if [[ $jq_exit -ne 0 || -z "$candidate_json" ]]; then
                        echo "  jq -s failed (exit=$jq_exit). Inspecting ${DIAG_DIR}/reset_band_jq_error.log"
                        if [[ -s "${DIAG_DIR}/reset_band_jq_error.log" ]]; then
                            echo "---- jq error (truncated) ----"
                            head -n 40 "${DIAG_DIR}/reset_band_jq_error.log" | sed 's/^/    /'
                            echo "---- end jq error ----"
                        fi
                        # Fallback: merge incrementally to tolerate partial/broken files
                        combined='{}'
                        for cf in "${candidate_files[@]}"; do
                            part=$(jq -c '.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } elif has("vps_id") then { ( (.vps_id|tostring) ): . } else {} end ) | add) else . end' "${cf}" 2>/dev/null || echo '{}')
                            # merge into combined
                            combined=$(jq -n --argjson a "$combined" --argjson b "$part" '$a + $b' 2>/dev/null || echo '{}')
                        done
                        # wrap into candidate_json
                        candidate_json=$(jq -n --argjson vs "$combined" '{vs: $vs}' 2>/dev/null || echo '{}')
                    fi

                    candidate_count=$(echo "$candidate_json" | jq -r '.vs | length' 2>/dev/null || echo 0)
                    # Save candidate merged JSON for inspection
                    echo "$candidate_json" > "${DIAG_DIR}/reset_band_candidate_${start_page}_merged.json" 2>/dev/null || true
                    echo "  Saved candidate merged JSON to ${DIAG_DIR}/reset_band_candidate_${start_page}_merged.json (size=$(stat -c%s \"${DIAG_DIR}/reset_band_candidate_${start_page}_merged.json\" 2>/dev/null || echo '?') bytes)"
                    echo "Candidate start=${start_page}: merged ${candidate_count} total VPS entries"
                else
                    candidate_json='{}'
                    candidate_count=0
                    echo "Candidate start=${start_page}: no pages saved, count=0"
                fi

                # If candidate is better, keep it
                if [[ $candidate_count -gt $best_count ]]; then
                    best_count=$candidate_count
                    best_json="$candidate_json"
                    echo "New best candidate: start=${start_page} with ${candidate_count} entries"
                fi

                # Clean up candidate temp pages
                rm -f "${DIAG_DIR}/reset_band_page_candidate_${start_page}_*.json" 2>/dev/null || true
            done

            # Use best result
            vs_json="$best_json"
            vps_count=$best_count
            # Save final merged JSON for inspection
            echo "$vs_json" > "${DIAG_DIR}/reset_band_merged_vs.json" 2>/dev/null || true
            echo "Saved merged VS JSON to ${DIAG_DIR}/reset_band_merged_vs.json (size=$(stat -c%s \"${DIAG_DIR}/reset_band_merged_vs.json\" 2>/dev/null || echo '?') bytes)"
            echo "Merged .vs type: $(echo "$vs_json" | jq -r '.vs | type' 2>/dev/null || echo 'unknown')"
        fi
        
        echo "All $vps_count VPS IDs in your system:"
        echo "$vs_json" | jq -r '.vs | keys[]' | sort -n | while read -r vpsid; do
            vps_name=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].vps_name // "unknown"')
            hostname=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].hostname // "unknown"')
            echo "  VPS $vpsid: $vps_name ($hostname)"
        done
        echo ""
        echo "Total: $vps_count VPS IDs listed."
        echo "Use any of these VPS IDs to test the bandwidth reset script."
        echo "Example: /root/vps_manager.sh --check-vps <VPS_ID>"
    else
        echo "Failed to fetch VPS list. Check API configuration."
        exit 2
    fi
    exit 0
fi

# List first 20 VPS IDs for quick preview - useful for quick VPS discovery
if [[ "${1:-}" == "--list-vps-preview" ]]; then
    load_config
    echo "Fetching VPS list preview (first 20 VPS IDs)..."
    # Build api_base same as run_reset_logic
    host_clean="${HOST#http://}"
    host_clean="${host_clean#https://}"
    api_base="https://${host_clean}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
    
    # Fetch only the first page with 20 VPS entries
    api_url="${api_base}&act=vs&api=json&reslen=20&page=1"
    response=$(curl -s -k "$api_url" 2>/dev/null)
    
    if [[ -n "$response" ]] && echo "$response" | jq -e '.vs' &>/dev/null; then
        vs_json="$response"
        vps_ids=($(echo "$vs_json" | jq -r '.vs | keys[]' | sort -n))
        vps_count=${#vps_ids[@]}
        
        if [[ $vps_count -eq 0 ]]; then
            echo "No VPS IDs found in the first 20 results."
            exit 0
        fi
        
        echo "Preview: First $vps_count VPS IDs found:"
        echo ""
        for vpsid in "${vps_ids[@]}"; do
            vps_name=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].vps_name // "unknown"')
            hostname=$(echo "$vs_json" | jq -r --arg vpsid "$vpsid" '.vs[$vpsid].hostname // "unknown"')
            echo "  VPS $vpsid: $vps_name ($hostname)"
        done
        echo ""
        echo "This is a preview of the first 20 VPS IDs."
        echo "Use --list-vps to see all VPS IDs in your system."
        echo "Example: /root/vps_manager.sh --check-vps <VPS_ID>"
    else
        echo "Failed to fetch VPS list preview. Check API configuration."
        exit 2
    fi
    exit 0
fi

# Quick check for a single VPS ID: non-interactive diagnostic that queries the API for one vpsid
if [[ "${1:-}" == "--check-vps" && -n "${2:-}" ]]; then
    load_config
    vps_to_check="$2"
    echo "Checking VPS ID $vps_to_check against configured API..."
    # Build api_base same as run_reset_logic
    host_clean="${HOST#http://}"
    host_clean="${host_clean#https://}"
    host_clean="${host_clean%%/}"
    if [[ -n "${API_BASE:-}" ]]; then
        api_base="$API_BASE"
        echo "Using API_BASE override from config."
    else
        if [[ "$host_clean" == *:* ]]; then
            api_base="https://${host_clean}/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
        else
            api_base="https://${host_clean}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
        fi
    fi
    api_url="${api_base}&act=vs&api=json&reslen=0"
    echo "API URL: $api_url"
    vs_json=$(curl -sS -L --max-redirs 5 "$api_url")
    curl_status=$?
    if (( curl_status != 0 )); then
        echo "API request failed (curl exit $curl_status). Check network and API credentials." >&2
        exit 2
    fi
    if [[ -z "$vs_json" ]]; then
        echo "API returned empty response. Check API endpoint and credentials." >&2
        exit 2
    fi
    if echo "$vs_json" | grep -qi '<html\|<script'; then
        echo "API response appears to be HTML (possible redirect or proxy). Response: $vs_json" >&2
        exit 2
    fi
    if ! echo "$vs_json" | jq -e '.vs' >/dev/null 2>&1; then
        echo "API response missing 'vs' field. Response: $vs_json" >&2
        exit 3
    fi
    vps_count=$(echo "$vs_json" | jq -r '.vs | length')
    if [[ "$vps_count" -le 50 ]]; then
        # Do paging
        rm -f "${DIAG_DIR}/reset_band_page_*.json" 2>/dev/null || true
        per=50
        page=0
        while true; do
            page_url="${api_base}&act=vs&api=json&reslen=${per}&page=${page}"
            curl -sS -L --max-redirs 5 -o "${DIAG_DIR}/reset_band_page_${page}.json" "$page_url"
            if ! jq -e '.vs' "${DIAG_DIR}/reset_band_page_${page}.json" >/dev/null 2>&1; then
                break
            fi
            page_count=$(jq -r '.vs | length' "${DIAG_DIR}/reset_band_page_${page}.json")
            if [[ "$page_count" -eq 0 ]]; then
                break
            fi
            page=$((page+1))
        done
        if ls "${DIAG_DIR}/reset_band_page_*.json" >/dev/null 2>&1; then
            vs_json=$(jq -s 'map(.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } elif has("vps_id") then { ( (.vps_id|tostring) ): . } else {} end ) | add) else . end) | add | {vs: .}' ${DIAG_DIR}/reset_band_page_*.json 2>/dev/null || echo '{}')
            rm -f "${DIAG_DIR}/reset_band_page_*.json" 2>/dev/null || true
            # Save merged JSON for inspection
            echo "$vs_json" > "${DIAG_DIR}/reset_band_merged_vs.json" 2>/dev/null || true
            echo "Saved merged VS JSON to ${DIAG_DIR}/reset_band_merged_vs.json"
        fi
    fi
    # Now check if the vpsid exists
    if jq -e --arg vpsid "$vps_to_check" '.vs[$vpsid]' <<<"$vs_json" >/dev/null 2>&1; then
        echo "VPS ID $vps_to_check FOUND in API response."
        exit 0
    else
        echo "VPS ID $vps_to_check NOT found in normal listing. Checking suspended VPSes..."
        
        # Try searching for suspended VPSes specifically
        suspended_url="${api_base}&act=vs&api=json&vsstatus=s&reslen=0"
        echo "Checking suspended VPSes: $suspended_url"
        suspended_json=$(curl -sS -L --max-redirs 5 "$suspended_url" || echo '{}')
        
        if jq -e --arg vpsid "$vps_to_check" '.vs[$vpsid]' <<<"$suspended_json" >/dev/null 2>&1; then
            echo "VPS ID $vps_to_check FOUND in SUSPENDED VPSes."
            vps_suspend_reason=$(echo "$suspended_json" | jq -r --arg vpsid "$vps_to_check" '.vs[$vpsid].suspend_reason // "Unknown"')
            echo "VPS Status: SUSPENDED (Reason: $vps_suspend_reason)"
            exit 0
        else
            echo "VPS ID $vps_to_check NOT found in suspended VPSes either. Checking unsuspended VPSes..."
            
            # Try searching for unsuspended VPSes specifically  
            unsuspended_url="${api_base}&act=vs&api=json&vsstatus=u&reslen=0"
            echo "Checking unsuspended VPSes: $unsuspended_url"
            unsuspended_json=$(curl -sS -L --max-redirs 5 "$unsuspended_url" || echo '{}')
            
            if jq -e --arg vpsid "$vps_to_check" '.vs[$vpsid]' <<<"$unsuspended_json" >/dev/null 2>&1; then
                echo "VPS ID $vps_to_check FOUND in UNSUSPENDED VPSes."
                exit 0
            else
                echo "VPS ID $vps_to_check NOT found in any API response (normal, suspended, or unsuspended)."
                exit 4
            fi
        fi
    fi
fi

# Support a diagnostic, non-interactive mode to capture curl verbose output
if [[ "${1:-}" == "--diagnose" ]]; then
    load_config
    echo "Running diagnostic mode: will attempt to fetch API and save curl logs to ${DIAG_DIR}/reset_band_curl_*.log"
    run_reset_logic "all" --diagnose
    echo "Diagnostic complete. Check ${DIAG_DIR}/reset_band_curl_verbose.log and ${DIAG_DIR}/reset_band_curl_headers.log"
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

