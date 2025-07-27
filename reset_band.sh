#!/usr/bin/env bash
set -euo pipefail
#
############################################################
# 0. CONFIG
############################################################
HOST="1.1.1.1"
KEY="206auOuotSOdxTDxW9POSW4IlAF9WwjD"
PASS="1YSlwHrSkhZyBxcAS8iJnEe1wUYaKhjm"

############################################################
# 1. LOG FILES
############################################################
log_file="/tmp/reset_band.log"
change_log="/tmp/reset_band_changes.log"
log_info()  { echo "$(date '+%F %T') [INFO]  $*"  | tee -a "$log_file"; }
log_error() { echo "$(date '+%F %T') [ERROR] $*" | tee -a "$log_file" >&2; }

############################################################
# 2. API BASE (creds in URL, as per docs)
############################################################
API_BASE="http://${HOST}:4084/index.php?adminapikey=${KEY}&adminapipass=${PASS}"

# health-check
code=$(curl -sSf -o /dev/null --connect-timeout 5 --max-time 10 \
        -w '%{http_code}' "${API_BASE}&act=version&api=json")
[[ $code == 200 ]] || { log_error "Panel unreachable (HTTP $code)"; exit 1; }
log_info "API reachable (HTTP 200)"

############################################################
# 3. ARGUMENTS
############################################################
usage(){ log_error "Usage: $0 -m <single|all> [-v id1,id2,…]"; exit 1; }
MODE="" VPS_LIST=""
while getopts "m:v:" o; do
  case $o in
    m) MODE=$OPTARG ;;
    v) VPS_LIST=$OPTARG ;;
    *) usage ;;
  esac
done
[[ -z $MODE ]] && usage

############################################################
# 4. TARGET VPS LIST
############################################################
if [[ $MODE == all ]]; then
  # MODIFIED LINE: Changed jq query to extract keys from the 'vs' object, which are the VPS IDs.
  mapfile -t VPS_IDS < \
    <(curl -sS "${API_BASE}&act=vs&api=json" | jq -r '.vs | keys_unsorted[]')
else
  IFS=',' read -ra VPS_IDS <<<"$VPS_LIST"
fi
log_info "Target VPS IDs: ${VPS_IDS[*]}"

############################################################
# 5. MAIN LOOP
############################################################
# Check if VPS_IDS array is empty
if [ ${#VPS_IDS[@]} -eq 0 ]; then
    log_info "No target VPSs found. Exiting."
    log_info "=== Completed ==="
    exit 0
fi

MONTH=$(date +%Y%m)
for VPSID in "${VPS_IDS[@]}"; do
  log_info "─ VPS $VPSID"

  # 5.1 fetch stats
  STATS=$(curl -sS "${API_BASE}&act=vps_stats&api=json&vpsid=${VPSID}&show=${MONTH}")
  jq -e . >/dev/null <<<"$STATS" || { log_error "$VPSID → stats not JSON"; continue; }

  # 5.2 extract and cast to int (strip decimals)
  LIMIT=$(jq -r ".vps_data.\"K_${VPSID}\".bandwidth        //0" <<<"$STATS" | awk '{printf "%d",$1}')
  USED=$( jq -r ".vps_data.\"K_${VPSID}\".used_bandwidth   //0" <<<"$STATS" | awk '{printf "%d",$1}')
  PLID=$( jq -r ".vps_data.\"K_${VPSID}\".plid           //0" <<<"$STATS" | awk '{printf "%d",$1}')
  (( LIMIT==0 )) && { log_error "$VPSID → unlimited plan; skip"; continue; }

  NEW_LIMIT=$(( LIMIT - USED )); (( NEW_LIMIT < 0 )) && NEW_LIMIT=0
  log_info "$VPSID : ${USED}/${LIMIT} GB → 0/${NEW_LIMIT} GB"

  # 5.3 reset counter (Admin API Reset-Bandwidth)
  RESET=$(curl -sS --connect-timeout 10 --max-time 30 \
          -w '\nHTTP_CODE:%{http_code}' \
          "${API_BASE}&act=vs&bwreset=${VPSID}&api=json")
  R_BODY=${RESET%$'\n'HTTP_CODE:*}; R_CODE=${RESET##*HTTP_CODE:}
  if [[ $R_CODE != 200 || $(jq -r '.done //0' <<<"$R_BODY") -ne 1 ]]; then
     log_error "$VPSID → reset failed (HTTP $R_CODE) body: $R_BODY"; continue
  fi
  log_info "Usage reset OK"

  # 5.4 update limit (preserving original plan)
  UPDATE=$(curl -sS --connect-timeout 10 --max-time 30 \
          -w '\nHTTP_CODE:%{http_code}' \
          -d "editvps=1" \
          -d "bandwidth=$NEW_LIMIT" \
          -d "plid=${PLID}" \
          "${API_BASE}&act=managevps&vpsid=${VPSID}&api=json")
  U_BODY=${UPDATE%$'\n'HTTP_CODE:*}; U_CODE=${UPDATE##*HTTP_CODE:}
  if [[ $U_CODE != 200 || $(jq -r '.done.done //false' <<<"$U_BODY") != true ]]; then
     log_error "$VPSID → update failed (HTTP $U_CODE) body: $U_BODY"; continue
  fi
  log_info "Limit updated (plan $PLID preserved)"

  # 5.5 audit line
  printf "%(%F %T)T  VPS %s  %d/%d => 0/%d (plan %d)\n" -1 \
         "$VPSID" "$USED" "$LIMIT" "$NEW_LIMIT" "$PLID" >>"$change_log"
done

log_info "=== Completed ==="
