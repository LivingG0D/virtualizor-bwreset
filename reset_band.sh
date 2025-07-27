#!/usr/bin/env bash
set -euo pipefail

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
for cmd in whiptail curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Command '$cmd' is not installed. Please install it to continue."
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
    source "$CONFIG_FILE"
}

configure_script() {
    # UI for editing the configuration file.
    local CURRENT_HOST=$HOST
    local CURRENT_KEY=$KEY
    local CURRENT_PASS=$PASS

    # The `|| return 0` is to prevent `set -e` from exiting the script if the user cancels.
    NEW_HOST=$(whiptail --title "Configure Host" --inputbox "Enter the Virtualizor Host IP:" 8 78 "$CURRENT_HOST" 3>&1 1>&2 2>&3) || return 0
    NEW_KEY=$(whiptail --title "Configure API Key" --inputbox "Enter the API Key:" 8 78 "$CURRENT_KEY" 3>&1 1>&2 2>&3) || return 0
    NEW_PASS=$(whiptail --title "Configure API Pass" --inputbox "Enter the API Password:" 8 78 "$CURRENT_PASS" 3>&1 1>&2 2>&3) || return 0

    {
        echo "HOST=\"$NEW_HOST\""
        echo "KEY=\"$NEW_KEY\""
        echo "PASS=\"$NEW_PASS\""
    } > "$CONFIG_FILE"
    whiptail --title "Success" --msgbox "Configuration has been updated in $CONFIG_FILE." 8 78
}

#================================================================
#   CORE RESET LOGIC
#================================================================
run_reset_logic() {
    local MODE=$1
    local ERROR_FLAG=0

    log_info()  { echo "$(date '+%F %T') [INFO]  $*"  | tee -a "$LOG_FILE"; }
    log_error() { echo "$(date '+%F %T') [ERROR] $*" | tee -a "$LOG_FILE" >&2; ERROR_FLAG=1; }

    local API_BASE="http://${HOST}:4084/index.php?adminapikey=${KEY}&adminapipass=${PASS}"

    log_info "Fetching server data..."
    local VS_JSON
    VS_JSON=$(curl -sS "${API_BASE}&act=vs&api=json")

    local VPS_IDS=()
    if [[ "$MODE" == "all" ]]; then
      mapfile -t VPS_IDS < <(echo "$VS_JSON" | jq -r '.vs | keys_unsorted[]')
    else
      if ! echo "$VS_JSON" | jq -e --arg vpsid "$MODE" '.vs[$vpsid]' > /dev/null; then
          log_error "VPS ID $MODE not found in API response."
          return 1
      fi
      VPS_IDS=("$MODE")
    fi
    log_info "Target VPS IDs: ${VPS_IDS[*]}"

    if [ ${#VPS_IDS[@]} -eq 0 ]; then
        log_info "No target VPSs found. Exiting."
        return 0
    fi

    for VPSID in "${VPS_IDS[@]}"; do
      log_info "─ VPS $VPSID"
      
      local LIMIT_STR
      LIMIT_STR=$(echo "$VS_JSON" | jq -r --arg vpsid "$VPSID" '.vs[$vpsid].bandwidth // 0')
      local LIMIT
      LIMIT=$(echo "$LIMIT_STR" | awk '{printf "%d", $1}')
      
      if (( LIMIT==0 )); then
          log_info "$VPSID → unlimited plan. Resetting usage only."
          local RESET
          RESET=$(curl -sS -X POST -w '\nHTTP_CODE:%{http_code}' "${API_BASE}&act=vs&bwreset=${VPSID}&api=json")
          local R_BODY=${RESET%$'\n'HTTP_CODE:*}; local R_CODE=${RESET##*HTTP_CODE:}
          if [[ $R_CODE != 200 || $(jq -r '.done //0' <<<"$R_BODY") -ne 1 ]]; then
             log_error "$VPSID → usage reset failed (HTTP $R_CODE) body: $R_BODY"
          else
             log_info "$VPSID → usage reset OK"
          fi
          continue
      fi

      local USED_STR
      USED_STR=$(echo "$VS_JSON" | jq -r --arg vpsid "$VPSID" '.vs[$vpsid].used_bandwidth // 0')
      local USED
      USED=$(echo "$USED_STR" | awk '{printf "%d", $1}')
      local PLID
      PLID=$(echo "$VS_JSON" | jq -r --arg vpsid "$VPSID" '.vs[$vpsid].plid // 0')
      
      local NEW_LIMIT=$(( LIMIT - USED )); (( NEW_LIMIT < 0 )) && NEW_LIMIT=0
      log_info "$VPSID : ${USED}/${LIMIT} GB → 0/${NEW_LIMIT} GB"
      
      local RESET
      RESET=$(curl -sS -X POST -w '\nHTTP_CODE:%{http_code}' "${API_BASE}&act=vs&bwreset=${VPSID}&api=json")
      local R_BODY=${RESET%$'\n'HTTP_CODE:*}; local R_CODE=${RESET##*HTTP_CODE:}
      if [[ $R_CODE != 200 || $(jq -r '.done //0' <<<"$R_BODY") -ne 1 ]]; then
         log_error "$VPSID → reset failed (HTTP $R_CODE) body: $R_BODY"; continue
      fi
      log_info "Usage reset OK"
      
      local UPDATE
      UPDATE=$(curl -sS -w '\nHTTP_CODE:%{http_code}' -d "editvps=1" -d "bandwidth=$NEW_LIMIT" -d "plid=${PLID}" "${API_BASE}&act=managevps&vpsid=${VPSID}&api=json")
      local U_BODY=${UPDATE%$'\n'HTTP_CODE:*}; local U_CODE=${UPDATE##*HTTP_CODE:}
      if [[ $U_CODE != 200 || $(jq -r '.done.done //false' <<<"$U_BODY") != true ]]; then
         log_error "$VPSID → update failed (HTTP $U_CODE) body: $U_BODY"; continue
      fi
      log_info "Limit updated (plan $PLID preserved)"
      printf "%(%F %T)T  VPS %s  %d/%d => 0/%d (plan %d)\n" -1 "$VPSID" "$USED" "$LIMIT" "$NEW_LIMIT" "$PLID" >>"$CHANGE_LOG"
    done
    log_info "=== Completed ==="
    return $ERROR_FLAG
}

#================================================================
#   UI & MENU FUNCTIONS
#================================================================
manual_reset_menu() {
    local CHOICE
    CHOICE=$(whiptail --title "Manual Bandwidth Reset" --menu "Choose an option" 15 60 2 \
        "1" "Reset ALL VPSs" \
        "2" "Reset a SPECIFIC VPS" 3>&1 1>&2 2>&3) || return 0

    case $CHOICE in
        1)
            whiptail --title "Confirm Reset All" --yesno "Are you sure you want to reset bandwidth for ALL servers?" 8 78
            if [ $? -eq 0 ]; then
                # Clear log file for a clean view of this run
                > "$LOG_FILE"
                whiptail --infobox "Processing all servers, please wait..." 8 78
                if run_reset_logic "all"; then
                    TITLE="Success"
                else
                    TITLE="Failed"
                fi
                whiptail --title "$TITLE" --textbox "$LOG_FILE" 20 78 --scrolltext
            fi
            ;;
        2)
            local VPS_ID
            VPS_ID=$(whiptail --title "Specific VPS Reset" --inputbox "Enter the VPS ID to reset:" 8 78 3>&1 1>&2 2>&3) || return 0
            if [ -n "$VPS_ID" ]; then
                # Clear log file for a clean view of this run
                > "$LOG_FILE"
                whiptail --infobox "Processing VPS $VPS_ID, please wait..." 8 78
                if run_reset_logic "$VPS_ID"; then
                    TITLE="Success"
                else
                    TITLE="Failed"
                fi
                whiptail --title "$TITLE" --textbox "$LOG_FILE" 20 78 --scrolltext
            fi
            ;;
    esac
}

automation_menu() {
    local CHOICE
    CHOICE=$(whiptail --title "Automation Management" --menu "Manage automated cron jobs" 17 78 5 \
        "1" "Enable DAILY Reset (00:00)" \
        "2" "Enable MONTHLY Reset (1st of month at 02:00)" \
        "3" "DISABLE Automation" \
        "4" "View Status" \
        "5" "Manually Edit Crontab (nano)" 3>&1 1>&2 2>&3) || return 0

    # Get the full, absolute path to the currently running script
    local SCRIPT_FULL_PATH
    SCRIPT_FULL_PATH=$(realpath "$0")

    case $CHOICE in
        1)
            local CURRENT_CRON
            CURRENT_CRON=$(crontab -l 2>/dev/null || true)
            local CLEAN_CRON
            CLEAN_CRON=$(echo "$CURRENT_CRON" | grep -vF "$CRON_TAG" || true)
            printf "%s\n%s\n" "$CLEAN_CRON" "0 0 * * * /usr/bin/bash $SCRIPT_FULL_PATH --cron $CRON_TAG" | sed '/^$/d' | crontab -
            whiptail --title "Success" --msgbox "Daily cron job enabled." 8 78
            ;;
        2)
            local CURRENT_CRON
            CURRENT_CRON=$(crontab -l 2>/dev/null || true)
            local CLEAN_CRON
            CLEAN_CRON=$(echo "$CURRENT_CRON" | grep -vF "$CRON_TAG" || true)
            printf "%s\n%s\n" "$CLEAN_CRON" "0 2 1 * * /usr/bin/bash $SCRIPT_FULL_PATH --cron $CRON_TAG" | sed '/^$/d' | crontab -
            whiptail --title "Success" --msgbox "Monthly cron job enabled." 8 78
            ;;
        3)
            (crontab -l 2>/dev/null || true) | grep -vF "$CRON_TAG" | crontab -
            whiptail --title "Success" --msgbox "All automation has been disabled." 8 78
            ;;
        4)
            local STATUS
            STATUS=$(crontab -l 2>/dev/null | grep "$CRON_TAG" || echo "Automation is currently disabled.")
            whiptail --title "Automation Status" --msgbox "$STATUS" 8 78
            ;;
        5)
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
    CHOICE=$(whiptail --title "VPS Bandwidth Manager by LivingGOD" --menu "Select an option" 16 60 4 \
        "1" "Configure Script" \
        "2" "Manual Reset" \
        "3" "Manage Automation" \
        "4" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case $CHOICE in
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
