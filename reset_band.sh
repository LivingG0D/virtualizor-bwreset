#!/usr/bin/env bash
#
# Virtualizor Bandwidth Carry-Over Manager
#
# Resets each VPS's bandwidth usage through the Virtualizor Admin API and lowers its
# limit by what was used, so only the unused quota remains (negative limits move
# towards zero instead). Built against the Admin API of Virtualizor 3.3.x.
#
# Author: LivingGOD
# License: Apache-2.0

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/vps_manager.conf}"
DIAG_DIR="${DIAG_DIR:-/root}"
LOG_FILE="${DIAG_DIR}/reset_band.log"
CHANGE_LOG="${DIAG_DIR}/reset_band_changes.log"
LOCK_FILE="${DIAG_DIR}/.reset_band.lock"
CRON_TAG="# vps-bandwidth-reset-cron"
DEFAULT_JOBS=5
PAGE_SIZE=50 # Virtualizor's default reslen
MAX_PAGES=1000
DRY_RUN=0

# Normalises a response's .vs (an object keyed by vpsid, or [] when empty) to an object.
JQ_VS='if has("vs") | not then error("response has no vs list") else .vs // {} end
  | if type == "array" then map({key: (.vpsid | tostring), value: .}) | from_entries else . end'
# One "vpsid limit used plid" line per VPS, in whole GB, ordered by vpsid ("invalid" when not a number).
JQ_WORK='def num: (tonumber? | floor) // "invalid";
  [.[] | select(.vpsid != null)] | sort_by(.vpsid | num) | .[]
  | [(.vpsid | tostring), (.bandwidth | num), (.used_bandwidth | num), (.plid | num)]
  | map(tostring) | join(" ")'

usage() {
    cat <<EOF
Usage: ${0##*/} [option]

  (no option)      interactive menu
  --cron           reset all VPSes (what the cron job runs)
  --dry-run [ID]   show what a reset of all VPSes (or one) would change, change nothing
  --list-vps       list VPSes with their bandwidth usage
  -h, --help       show this help

Environment: CONFIG_FILE (default /etc/vps_manager.conf), DIAG_DIR (logs, default /root)
EOF
}

# --- Logging ---
# Everything logs to stderr; each line is one write, so parallel workers never interleave mid-line.
log_info() { printf '%s [INFO]  %s\n' "$(date '+%F %T')" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() {
    log_error "$@"
    exit 1
}
audit() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$CHANGE_LOG"; }

check_dependencies() {
    local dep
    for dep; do
        command -v "$dep" >/dev/null || die "Required command '$dep' is not installed."
    done
}

# --- Config ---
load_config() {
    [[ -f $CONFIG_FILE ]] || return 1
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true # older versions wrote it world-readable
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" || die "Cannot read $CONFIG_FILE"
    HOST="${HOST:-}" KEY="${KEY:-}" PASS="${PASS:-}" API_BASE="${API_BASE:-}"
    [[ ${PARALLEL_JOBS:-} =~ ^[1-9][0-9]*$ ]] || PARALLEL_JOBS=$DEFAULT_JOBS
}

# Values are written with %q so credentials containing quotes or $ survive being sourced.
save_config() {
    (umask 077 && : >>"$CONFIG_FILE")
    chmod 600 "$CONFIG_FILE"
    {
        printf 'HOST=%q\nKEY=%q\nPASS=%q\n' "${HOST:-}" "${KEY:-}" "${PASS:-}"
        printf '# Optional: full API URL override, including adminapikey and adminapipass\nAPI_BASE=%q\n' "${API_BASE:-}"
        printf '# Number of VPSes processed in parallel\nPARALLEL_JOBS=%q\n' "${PARALLEL_JOBS:-$DEFAULT_JOBS}"
    } >"$CONFIG_FILE"
}

# --- Admin API ---
# Input on stdin, not argv, so the credentials stay out of `ps`.
urlencode() { printf '%s' "$1" | jq -sRr '@uri'; }

# Prints https://HOST:4085/index.php?adminapikey=...&adminapipass=... (or API_BASE when set).
api_url() {
    if [[ -n $API_BASE ]]; then
        echo "$API_BASE"
        return
    fi
    local scheme=https host=$HOST
    if [[ $host == http://* ]]; then scheme=http; fi
    host=${host#*://}
    host=${host%%/*}
    [[ $host =~ :[0-9]+$ ]] || host+=":4085"
    printf '%s://%s/index.php?adminapikey=%s&adminapipass=%s\n' \
        "$scheme" "$host" "$(urlencode "$KEY")" "$(urlencode "$PASS")"
}

# api <query> [curl args...]: calls the Admin API and prints the raw body.
# The URL reaches curl on stdin so the credentials never show up in `ps`.
api() {
    local query=$1
    shift
    printf 'url = "%s&api=json&%s"\n' "$API_URL" "$query" |
        curl -sS -L --max-redirs 3 --connect-timeout 10 --max-time 300 --retry 3 -K - "$@"
}

# api_json <query> [curl args...]: like api, but fails unless the body is a JSON object with no error.
api_json() {
    local body
    if ! body=$(api "$@"); then
        log_error "Request failed: $1"
        return 1
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$body"; then
        log_error "Not a JSON API response for $1 (check host, port and credentials): ${body:0:200}"
        return 1
    fi
    if jq -e '(.error // []) | length > 0' >/dev/null 2>&1 <<<"$body"; then
        log_error "API error for $1: $(jq -c '.error' <<<"$body")"
        return 1
    fi
    printf '%s\n' "$body"
}

# Virtualizor reports success as done=1 (bwreset) or done.done=true (managevps).
is_done() {
    jq -e '.done | if type == "object" then .done else . end | . == true or . == 1 or . == "1"' \
        >/dev/null 2>&1 <<<"$1"
}

# --- VPS list ---
# merge_page <page>: merges one act=vs page into all.json; prints "<VPSes on page> <new VPS IDs>".
merge_page() {
    local before
    # Explicit || return 1: errexit is off inside $(...) and on the left of ||.
    api_json "act=vs&page=$1&reslen=${PAGE_SIZE}" >"$TMP_DIR/page.json" || return 1
    jq -c "$JQ_VS" "$TMP_DIR/page.json" >"$TMP_DIR/p.json" || return 1
    before=$(jq length "$TMP_DIR/all.json") || return 1
    jq -cs '.[0] + .[1]' "$TMP_DIR/all.json" "$TMP_DIR/p.json" >"$TMP_DIR/m.json" || return 1
    mv "$TMP_DIR/m.json" "$TMP_DIR/all.json" || return 1
    echo "$(jq length "$TMP_DIR/p.json") $(($(jq length "$TMP_DIR/all.json") - before))"
}

# Writes every VPS to $TMP_DIR/all.json, keyed by vpsid. Pages are 1-based as in the official
# SDK; paging stops at the first page that adds no new VPS ID (end of list, or a server that
# ignores page). Page 0 is merged last in case a server counts pages from 0.
fetch_all_vps() {
    local page stats count new
    echo '{}' >"$TMP_DIR/all.json"
    for ((page = 1; page <= MAX_PAGES; page++)); do
        stats=$(merge_page "$page") || return 1
        read -r count new <<<"$stats"
        ((count > 0 && new > 0)) || break
    done
    merge_page 0 >/dev/null 2>&1 || log_info "API does not accept page=0, ignored"
    log_info "Fetched $(jq length "$TMP_DIR/all.json") VPS(s)"
}

# fetch_one_vps <vpsid>: writes {"<vpsid>": {...}} (or {} when missing) to $TMP_DIR/all.json.
fetch_one_vps() {
    # shellcheck disable=SC2016 # $id is a jq variable
    local id=$1 pick='if has($id) then {($id): .[$id]} else {} end'
    api_json "act=vs&search=1&page=1&reslen=${PAGE_SIZE}&vpsid=${id}" >"$TMP_DIR/page.json" || return 1
    jq -c --arg id "$id" "$JQ_VS | $pick" "$TMP_DIR/page.json" >"$TMP_DIR/one.json" || return 1
    if [[ $(jq length "$TMP_DIR/one.json") == 0 ]]; then
        log_info "VPS $id not in search results, scanning the full list"
        fetch_all_vps || return 1
        jq -c --arg id "$id" "$pick" "$TMP_DIR/all.json" >"$TMP_DIR/one.json" || return 1
    fi
    mv "$TMP_DIR/one.json" "$TMP_DIR/all.json" || return 1
}

list_vps() {
    API_URL=$(api_url)
    fetch_all_vps || return 1
    printf 'VPSID\tNAME\tHOSTNAME\tUSED/LIMIT (GB)\tSTATUS\n'
    jq -r '[.[]] | sort_by(.vpsid | tonumber? // 0) | .[]
        | [.vpsid, .vps_name, .hostname, "\(.used_bandwidth // 0)/\(.bandwidth // 0)",
           (if (.suspended | tostring) == "1" then "suspended" else "active" end)]
        | map(. // "-" | tostring) | join("\t")' "$TMP_DIR/all.json"
}

# --- Carry-over ---
# carry_over <limit> <used>: prints the new limit (nothing for unlimited 0 plans);
# fails when usage reaches a positive limit, which means the VPS is skipped
# (a new limit of 0 would make the VPS unlimited).
carry_over() {
    local limit=$1 used=$2
    if ((limit == 0)); then return 0; fi
    if ((limit > 0 && used >= limit)); then return 1; fi
    if ((limit < 0)); then
        echo $((limit + used))
    else
        echo $((limit - used))
    fi
}

# process_vps <vpsid> <limit> <used> <plid>: runs in a parallel worker (no errexit there).
# Usage is reset before the limit is lowered: if the update then fails, the VPS keeps its old
# limit with zero usage instead of being charged twice.
process_vps() {
    local id=$1 limit=$2 used=$3 plid=$4 new body
    if [[ ! $limit =~ ^-?[0-9]+$ || ! $used =~ ^[0-9]+$ || ! $plid =~ ^[0-9]+$ ]]; then
        log_error "VPS $id: bandwidth, used_bandwidth or plid missing or not a number, skipped"
        return 1
    fi
    if ! new=$(carry_over "$limit" "$used"); then
        log_info "VPS $id: used ${used} GB >= limit ${limit} GB, skipped"
        if ((!DRY_RUN)); then
            audit "VPS $id  SKIPPED used=$used limit=$limit (plan $plid)"
        fi
        return 0
    fi
    if ((DRY_RUN)); then
        log_info "VPS $id: [dry run] would reset ${used}/${limit} GB -> 0/${new:-$limit} GB"
        return 0
    fi

    body=$(api_json "act=vs&bwreset=${id}")
    if ! is_done "$body"; then
        log_error "VPS $id: usage reset failed: ${body:-no valid response}"
        return 1
    fi
    if [[ -z $new ]]; then
        log_info "VPS $id: unlimited plan, usage reset"
        audit "VPS $id  ${used}/0 => 0/0 (unlimited, plan $plid)"
        return 0
    fi

    body=$(api_json "act=managevps&vpsid=${id}" --data editvps=1 --data theme_edit=1 \
        --data "bandwidth=${new}" --data "plid=${plid}")
    if ! is_done "$body"; then
        log_error "VPS $id: usage reset but limit update failed; set its limit to ${new} GB by hand (was ${limit}, used ${used}): ${body:-no valid response}"
        audit "VPS $id  ${used}/${limit} => 0/${limit} LIMIT UPDATE FAILED, set limit to ${new} (plan $plid)"
        return 1
    fi
    log_info "VPS $id: ${used}/${limit} GB -> 0/${new} GB (plan $plid preserved)"
    audit "VPS $id  ${used}/${limit} => 0/${new} (plan $plid)"
}

# run_reset all|<vpsid>
run_reset() {
    local target=$1 worklist="$TMP_DIR/worklist" count mode=""
    if [[ $target != all && ! $target =~ ^[0-9]+$ ]]; then
        log_error "Invalid VPS ID: $target"
        return 1
    fi
    exec 9>>"$LOCK_FILE"
    # flock ships with util-linux on every Linux node; skipped where absent (macOS test runs).
    if command -v flock >/dev/null && ! flock -n 9; then
        log_error "Another run is in progress (lock: $LOCK_FILE)"
        return 1
    fi
    if ((DRY_RUN)); then mode=", dry run"; fi
    log_info "=== Bandwidth reset started (target: ${target}${mode}) ==="

    API_URL=$(api_url)
    if [[ $target == all ]]; then
        fetch_all_vps || return 1
    else
        fetch_one_vps "$target" || return 1
    fi
    jq -r "$JQ_WORK" "$TMP_DIR/all.json" >"$worklist" || return 1
    count=$(($(wc -l <"$worklist")))
    if ((count == 0)); then
        if [[ $target != all ]]; then
            log_error "VPS $target not found"
            return 1
        fi
        log_info "No VPS to process"
        return 0
    fi

    log_info "Processing $count VPS(s) with $PARALLEL_JOBS parallel job(s)"
    export API_URL CHANGE_LOG DRY_RUN
    export -f process_vps carry_over api api_json is_done log_info log_error audit
    # shellcheck disable=SC2016 # $@ expands inside the worker shell
    if ! xargs -P "$PARALLEL_JOBS" -n 4 "$BASH" -c 'process_vps "$@"' _ <"$worklist"; then
        log_error "=== Finished with errors (see above) ==="
        return 1
    fi
    log_info "=== Finished ==="
}

# --- Interactive menus ---
# run_in_ui <target> [dry_run]: runs a reset, appends its output to the log and shows it.
run_in_ui() {
    local run_log="$TMP_DIR/run.log" title="Success"
    whiptail --infobox "Processing, please wait..." 8 78
    (
        DRY_RUN=${2:-0}
        run_reset "$1"
    ) >"$run_log" 2>&1 || title="Failed"
    cat "$run_log" >>"$LOG_FILE"
    whiptail --title "$title" --scrolltext --textbox "$run_log" 20 78
}

menu_configure() {
    local host key pass jobs
    host=$(whiptail --title "Configure" --inputbox "Virtualizor master IP or hostname (optional :port, default 4085):" \
        10 78 "${HOST:-}" 3>&1 1>&2 2>&3) || return 0
    # Stored secrets are not prefilled: whiptail arguments are visible in `ps`.
    key=$(whiptail --title "Configure" --inputbox "Admin API key (blank keeps the current one):" \
        8 78 3>&1 1>&2 2>&3) || return 0
    pass=$(whiptail --title "Configure" --passwordbox "Admin API password (blank keeps the current one):" \
        8 78 3>&1 1>&2 2>&3) || return 0
    jobs=$(whiptail --title "Configure" --inputbox "VPSes processed in parallel:" 8 78 \
        "${PARALLEL_JOBS:-$DEFAULT_JOBS}" 3>&1 1>&2 2>&3) || return 0
    if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
        whiptail --msgbox "Parallel jobs must be a positive whole number. Nothing saved." 8 78
        return 0
    fi
    HOST=$host KEY=${key:-$KEY} PASS=${pass:-$PASS} PARALLEL_JOBS=$jobs
    save_config
    whiptail --msgbox "Configuration saved to $CONFIG_FILE" 8 78
}

menu_manual() {
    local choice target
    choice=$(whiptail --title "Manual Reset" --menu "Choose an option" 15 60 3 \
        "1" "Reset ALL VPSs" \
        "2" "Reset a specific VPS" \
        "3" "Dry run for ALL VPSs (no changes)" 3>&1 1>&2 2>&3) || return 0
    case $choice in
        1) if whiptail --title "Confirm" --yesno "Reset bandwidth for ALL VPSs?" 8 78; then run_in_ui all; fi ;;
        2) if target=$(whiptail --title "Reset a VPS" --inputbox "VPS ID:" 8 78 3>&1 1>&2 2>&3) && [[ -n $target ]]; then
            run_in_ui "$target"
        fi ;;
        3) run_in_ui all 1 ;;
    esac
}

# set_cron [schedule and command]: replaces this script's crontab entry; no argument removes it.
# Leaves the crontab alone if it cannot be read, so other jobs are never wiped.
set_cron() {
    local current
    if ! current=$(crontab -l 2>&1); then
        if [[ $current != *"no crontab"* ]]; then
            whiptail --title "Automation" --msgbox "crontab -l failed, nothing changed: $current" 10 78
            return 0
        fi
        current=""
    fi
    {
        if [[ -n $current ]]; then printf '%s\n' "$current" | grep -vF "$CRON_TAG" || true; fi
        if [[ -n ${1:-} ]]; then echo "$1 $CRON_TAG"; fi
    } | crontab -
}

menu_automation() {
    local choice cmd current
    cmd=$(printf '%q %q --cron' "$BASH" "$(realpath "$0")")
    current=$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" || true)
    choice=$(whiptail --title "Automation" --menu "Current: ${current:-disabled}" 20 78 5 \
        "1" "Enable DAILY reset (00:00)" \
        "2" "Enable MONTHLY reset (1st of month, 02:00)" \
        "3" "Enable LAST DAY of month reset (23:30)" \
        "4" "Disable automation" \
        "5" "Edit crontab manually" 3>&1 1>&2 2>&3) || return 0
    case $choice in
        1) set_cron "0 0 * * * $cmd" ;;
        2) set_cron "0 2 1 * * $cmd" ;;
        # cron runs this with /bin/sh: POSIX test, and % must be escaped.
        3) set_cron "30 23 28-31 * * [ \"\$(date -d tomorrow +\\%d)\" = 01 ] && $cmd" ;;
        4) set_cron ;;
        5) EDITOR="${EDITOR:-nano}" crontab -e || true ;;
    esac
    current=$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" || true)
    whiptail --title "Automation" --msgbox "${current:-Automation is disabled.}" 10 78
}

interactive() {
    check_dependencies whiptail
    if ! load_config; then
        PARALLEL_JOBS=$DEFAULT_JOBS
        save_config
        load_config
        whiptail --msgbox "Created $CONFIG_FILE. Choose Configure to enter your API credentials." 8 78
    fi
    local choice
    while choice=$(whiptail --title "VPS Bandwidth Manager by LivingGOD" --menu "Select an option" 15 60 4 \
        "1" "Configure" \
        "2" "Manual Reset" \
        "3" "Automation" \
        "4" "Exit" 3>&1 1>&2 2>&3); do
        case $choice in
            1) menu_configure ;;
            2) menu_manual ;;
            3) menu_automation ;;
            *) break ;;
        esac
    done
}

main() {
    check_dependencies curl jq
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    case ${1:-} in
        "") interactive ;;
        --cron)
            load_config || die "Config not found: $CONFIG_FILE"
            exec >>"$LOG_FILE" 2>&1
            run_reset all
            ;;
        --dry-run)
            load_config || die "Config not found: $CONFIG_FILE"
            DRY_RUN=1
            run_reset "${2:-all}"
            ;;
        --list-vps)
            load_config || die "Config not found: $CONFIG_FILE"
            list_vps
            ;;
        -h | --help) usage ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
