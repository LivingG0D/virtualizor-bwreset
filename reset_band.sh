#!/usr/bin/env bash
#
# VPS Bandwidth Carry-Over Manager
# Refactored for modern practices and parallel processing.
#
# Original Author: LivingGOD
# Refactored by: Jules

set -euo pipefail

# --- Configuration & Constants ---
CONFIG_FILE="${CONFIG_FILE:-/etc/vps_manager.conf}"
CRON_TAG="# vps-bandwidth-reset-cron"
# DIAG_DIR default to /root, can be overridden
DIAG_DIR="${DIAG_DIR:-/root}"
LOG_FILE="${DIAG_DIR}/reset_band.log"
CHANGE_LOG="${DIAG_DIR}/reset_band_changes.log"
TEMP_DIR="/tmp/vps_manager_$(date +%s)_$$"

# Default configuration values
DEFAULT_JOBS=5

# --- Dependencies Check ---
check_dependencies() {
    local deps=(whiptail curl jq)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: Command '$dep' is not installed." >&2
            exit 1
        fi
    done
}

# --- Cleanup ---
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# --- Logging ---
# Main process logs to stderr so it doesn't interfere with captured stdout (e.g. JSON fetching)
log_info() {
    echo "$(date '+%F %T') [INFO]  $*" >&2
}
log_error() {
    echo "$(date '+%F %T') [ERROR] $*" >&2
}

# --- Config Management ---
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    source "$CONFIG_FILE"
    PARALLEL_JOBS="${PARALLEL_JOBS:-$DEFAULT_JOBS}"
    return 0
}

create_default_config() {
    if [[ -f "$CONFIG_FILE" ]]; then return; fi
    cat > "$CONFIG_FILE" <<EOF
HOST=""
KEY=""
PASS=""
# Optional: full API base URL override
API_BASE=""
# Number of parallel processes for resetting
PARALLEL_JOBS=5
EOF
}

configure_script_ui() {
    local current_host="${HOST:-}"
    local current_key="${KEY:-}"
    local current_pass="${PASS:-}"
    local current_jobs="${PARALLEL_JOBS:-$DEFAULT_JOBS}"

    local new_host new_key new_pass new_jobs
    new_host=$(whiptail --title "Configure Host" --inputbox "Virtualizor Host IP:" 8 78 "$current_host" 3>&1 1>&2 2>&3) || return 0
    new_key=$(whiptail --title "Configure API Key" --inputbox "API Key:" 8 78 "$current_key" 3>&1 1>&2 2>&3) || return 0
    new_pass=$(whiptail --title "Configure API Pass" --inputbox "API Password:" 8 78 "$current_pass" 3>&1 1>&2 2>&3) || return 0
    new_jobs=$(whiptail --title "Parallel Jobs" --inputbox "Number of parallel jobs:" 8 78 "$current_jobs" 3>&1 1>&2 2>&3) || return 0

    cat > "$CONFIG_FILE" <<EOF
HOST="$new_host"
KEY="$new_key"
PASS="$new_pass"
API_BASE=""
PARALLEL_JOBS=$new_jobs
EOF
    whiptail --msgbox "Configuration saved to $CONFIG_FILE" 8 78
}

# --- API Helpers ---
get_api_base() {
    local host_clean="${HOST#http://}"
    host_clean="${host_clean#https://}"
    host_clean="${host_clean%%/}"

    if [[ -n "${API_BASE:-}" ]]; then
        echo "$API_BASE"
    elif [[ "$host_clean" == *:* ]]; then
        echo "https://${host_clean}/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
    else
        echo "https://${host_clean}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
    fi
}

api_request() {
    local url="$1"
    local post_data="${2:-}"

    if [[ -n "$post_data" ]]; then
        curl -sS -L --max-redirs 5 --retry 3 -d "$post_data" "$url"
    else
        curl -sS -L --max-redirs 5 --retry 3 "$url"
    fi
}

# --- VPS Data Fetching ---
fetch_vps_data() {
    local api_base="$1"
    # Try fetching all at once
    local res
    res=$(api_request "${api_base}&act=vs&api=json&reslen=0")

    if [[ -z "$res" ]]; then
        log_error "API returned empty response"
        return 1
    fi

    # Check validity
    if ! echo "$res" | jq -e '.vs' >/dev/null 2>&1; then
        # Could be server list or error
        log_error "API response missing 'vs' field"
        return 1
    fi

    # Check count. If small, might need paging (Virtualizor default 50)
    local count
    count=$(echo "$res" | jq -r '.vs | length')

    if (( count <= 50 )); then
        log_info "Small result set ($count), attempting pagination to ensure all VPS are retrieved..."
        # Paging strategy: Try 0-based and 1-based, merge everything.
        local pages_dir="${TEMP_DIR}/pages"
        mkdir -p "$pages_dir"

        # We will fetch until we get an empty page.
        # We start at 0, go up to reasonable limit or empty
        local page=0
        local empty_streak=0

        while (( empty_streak < 2 )); do
             local p_url="${api_base}&act=vs&api=json&reslen=50&page=${page}"
             local p_file="${pages_dir}/page_${page}.json"
             api_request "$p_url" > "$p_file"

             local p_len
             p_len=$(jq -r '.vs | length' "$p_file" 2>/dev/null || echo 0)

             if (( p_len == 0 )); then
                 rm "$p_file"
                 ((empty_streak++))
             else
                 empty_streak=0
             fi
             ((page++))
             # Safety break
             if (( page > 1000 )); then break; fi
        done

        # Merge all pages
        if ls "${pages_dir}"/*.json >/dev/null 2>&1; then
            # Merge logic: array to object if needed
            jq -s 'map(.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } else {} end ) | add) else . end) | add | {vs: .}' "${pages_dir}"/*.json
            return 0
        fi
    fi

    # Return initial result if no paging needed or paging failed to find more
    echo "$res"
}

# --- Worker Logic ---
process_vps_worker() {
    local vpsid="$1"
    local limit="$2"
    local used="$3"
    local plid="$4"
    local api_base="$5"
    local log_file="$6"
    local change_log_file="$7"

    # Redirect output to log file
    exec > "$log_file" 2>&1

    log_info "─ VPS $vpsid"

    # Logic
    if (( limit == 0 )); then
        log_info "$vpsid → unlimited plan. Resetting usage only."
        local res
        res=$(curl -sS -X POST "${api_base}&act=vs&bwreset=${vpsid}&api=json")
        if echo "$res" | jq -e '.done // 0' | grep -q 1; then
            log_info "$vpsid → usage reset OK"
        else
            log_error "$vpsid → reset failed: $res"
            return 1
        fi
        return 0
    fi

    if (( limit > 0 )) && (( used > limit )); then
        log_info "$vpsid : used ($used) > limit ($limit) — skipping"
        local date_str
        date_str=$(date '+%F %T')
        printf "%s  VPS %s  SKIPPED used=%d limit=%d (plan %d)\n" "$date_str" "$vpsid" "$used" "$limit" "$plid" >> "$change_log_file"
        return 0
    fi

    local new_limit
    if (( limit < 0 )); then
        new_limit=$(( limit + used ))
    else
        new_limit=$(( limit - used ))
    fi

    log_info "$vpsid : ${used}/${limit} GB → 0/${new_limit} GB"

    # Reset
    local res
    res=$(curl -sS -X POST "${api_base}&act=vs&bwreset=${vpsid}&api=json")
    if ! echo "$res" | jq -e '.done // 0' | grep -q 1; then
        log_error "$vpsid → reset failed: $res"
        return 1
    fi

    # Update
    local u_res
    u_res=$(curl -sS -d "editvps=1" -d "bandwidth=$new_limit" -d "plid=${plid}" "${api_base}&act=managevps&vpsid=${vpsid}&api=json")

    if echo "$u_res" | jq -e '.done.done // false' | grep -q true; then
        log_info "Limit updated (plan $plid preserved)"
        local date_str
        date_str=$(date '+%F %T')
        printf "%s  VPS %s  %d/%d => 0/%d (plan %d)\n" "$date_str" "$vpsid" "$used" "$limit" "$new_limit" "$plid" >> "$change_log_file"
    else
        log_error "$vpsid → update failed: $u_res"
        return 1
    fi
}
export -f process_vps_worker log_info log_error

worker_wrapper() {
    # Unpack line: "101 1000 500 1"
    read -r vpsid limit used plid <<< "$1"
    # Paths exported
    process_vps_worker "$vpsid" "$limit" "$used" "$plid" "$API_BASE_VAL" "${LOGS_DIR}/${vpsid}.log" "${CHANGE_LOGS_DIR}/${vpsid}.log"
}
export -f worker_wrapper

# --- Main Reset Orchestrator ---
run_reset() {
    local target="$1" # "all" or vpsid
    local api_base
    api_base=$(get_api_base)

    log_info "Fetching VPS data..."
    local vs_json
    vs_json=$(fetch_vps_data "$api_base") || return 1

    mkdir -p "$TEMP_DIR"
    local worklist="${TEMP_DIR}/worklist.txt"

    if [[ "$target" == "all" ]]; then
        echo "$vs_json" | jq -r '.vs[] | "\(.vpsid) \(.bandwidth//0) \(.used_bandwidth//0) \(.plid//0)"' > "$worklist"
    else
        echo "$vs_json" | jq -r --arg id "$target" '.vs[$id] | "\(.vpsid) \(.bandwidth//0) \(.used_bandwidth//0) \(.plid//0)"' > "$worklist"
        if grep -q "null" "$worklist" || [[ ! -s "$worklist" ]]; then
             # Try finding in suspended/unsuspended lists if not found (Diagnostic feature from original)
             # For brevity, in this clean impl, we will trust the full fetch (which does paging).
             # If fetch_vps_data works correctly, it gets everything.
             log_error "VPS $target not found in list."
             return 1
        fi
    fi

    local count
    count=$(wc -l < "$worklist")
    if (( count == 0 )); then
        log_info "No VPS to process."
        return 0
    fi

    log_info "Processing $count VPS(s) with $PARALLEL_JOBS jobs..."

    # Setup log dirs
    export LOGS_DIR="${TEMP_DIR}/logs"
    export CHANGE_LOGS_DIR="${TEMP_DIR}/changelogs"
    export API_BASE_VAL="$api_base"
    mkdir -p "$LOGS_DIR" "$CHANGE_LOGS_DIR"

    # Execute
    # We strip trailing empty lines to avoid issues with read
    grep -v '^$' "$worklist" | xargs -P "$PARALLEL_JOBS" -L 1 -I {} bash -c 'worker_wrapper "$1"' _ "{}"

    # Aggregate logs
    log_info "Aggregating logs..."
    if ls "$LOGS_DIR"/*.log >/dev/null 2>&1; then
        cat "$LOGS_DIR"/*.log >> "$LOG_FILE"
    fi
    if ls "$CHANGE_LOGS_DIR"/*.log >/dev/null 2>&1; then
        cat "$CHANGE_LOGS_DIR"/*.log >> "$CHANGE_LOG"
    fi

    log_info "Done."
}

# --- Menus ---
menu_manual() {
    local choice
    choice=$(whiptail --title "Manual Reset" --menu "Select Option" 15 60 2 \
        "1" "Reset ALL VPSs" \
        "2" "Reset Specific VPS" 3>&1 1>&2 2>&3) || return

    case "$choice" in
        1)
            if whiptail --yesno "Reset ALL VPS bandwidth?" 8 78; then
                > "$LOG_FILE"
                {
                    run_reset "all" && echo "Success" || echo "Failed"
                } 2>&1 | tee -a "$LOG_FILE" | whiptail --programbox "Running..." 20 78
            fi
            ;;
        2)
            local vid
            vid=$(whiptail --inputbox "Enter VPS ID:" 8 78 3>&1 1>&2 2>&3) || return
            if [[ -n "$vid" ]]; then
                > "$LOG_FILE"
                 {
                    run_reset "$vid" && echo "Success" || echo "Failed"
                } 2>&1 | tee -a "$LOG_FILE" | whiptail --programbox "Running..." 20 78
            fi
            ;;
    esac
}

menu_automation() {
    local script_path
    script_path=$(realpath "$0")
    local choice
    choice=$(whiptail --title "Automation" --menu "Manage Cron" 18 78 5 \
        "1" "Enable Daily (00:00)" \
        "2" "Enable Monthly (1st, 02:00)" \
        "3" "Enable Last Day (23:30)" \
        "4" "Disable All" \
        "5" "Edit Crontab" 3>&1 1>&2 2>&3) || return

    local cron_cmd="/usr/bin/bash $script_path --cron"
    local current_cron
    current_cron=$(crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true)

    case "$choice" in
        1)
            printf "%s\n0 0 * * * %s %s\n" "$current_cron" "$cron_cmd" "$CRON_TAG" | crontab -
            whiptail --msgbox "Daily cron enabled." 8 78
            ;;
        2)
            printf "%s\n0 2 1 * * %s %s\n" "$current_cron" "$cron_cmd" "$CRON_TAG" | crontab -
            whiptail --msgbox "Monthly cron enabled." 8 78
            ;;
        3)
            local ld_cmd="30 23 * * * [ \"\$(date +\\%d -d tomorrow)\" == \"01\" ] && $cron_cmd $CRON_TAG"
            printf "%s\n%s\n" "$current_cron" "$ld_cmd" | crontab -
            whiptail --msgbox "Last day cron enabled." 8 78
            ;;
        4)
            echo "$current_cron" | crontab -
            whiptail --msgbox "Automation disabled." 8 78
            ;;
        5)
            EDITOR=nano crontab -e
            ;;
    esac
}

# --- Entry Point ---

# Check dependencies first (except if just checking version/help?)
check_dependencies

if [[ "${1:-}" == "--cron" ]]; then
    if ! load_config; then
        log_error "Config not found at $CONFIG_FILE"
        exit 1
    fi
    # Redirect stdout/stderr to logfile in cron mode
    exec >> "$LOG_FILE" 2>&1
    run_reset "all"
    exit 0
fi

# Diagnostic / CLI modes
if [[ "${1:-}" == "--list-vps" ]]; then
    if ! load_config; then echo "Config missing."; exit 1; fi
    api_base=$(get_api_base)
    echo "Fetching VPS list..."
    res=$(fetch_vps_data "$api_base")
    echo "$res" | jq -r '.vs[] | "VPS \(.vpsid): \(.vps_name) (\(.hostname))"'
    exit 0
fi

# Interactive Mode
if ! load_config; then
    create_default_config
    whiptail --msgbox "Created default config at $CONFIG_FILE. Please configure." 8 78
fi

while true; do
    choice=$(whiptail --title "VPS Manager" --menu "Main Menu" 15 60 4 \
        "1" "Configure" \
        "2" "Manual Reset" \
        "3" "Automation" \
        "4" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
        1) configure_script_ui; load_config ;;
        2) menu_manual ;;
        3) menu_automation ;;
        4) exit 0 ;;
    esac
done
