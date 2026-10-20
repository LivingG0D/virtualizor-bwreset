#!/usr/bin/env bash
# Tests reset_band.sh: carry-over math, URL building, and full runs against a mock Virtualizor API.
# Usage: bash tests/test_reset_band.sh   (needs bash, curl, jq, python3)
# shellcheck disable=SC2034,SC2016 # globals are read by the sourced script; literal $x is test data
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
mock_pid=""
trap '[[ -n $mock_pid ]] && kill "$mock_pid" 2>/dev/null && wait "$mock_pid" 2>/dev/null; rm -rf "$work"' EXIT
fails=0
check() {
    local desc=$1
    shift
    if "$@"; then echo "ok   - $desc"; else
        echo "FAIL - $desc"
        fails=$((fails + 1))
    fi
}
not() { ! "$@"; }

# --- Unit tests (functions sourced, main not run) ---
# shellcheck source=reset_band.sh
source ./reset_band.sh
set +e # the sourced script turns errexit on; checks must keep going

check "regular plan: limit minus used" [ "$(carry_over 1000 300)" = 700 ]
check "regular plan: used == limit is skipped (0 means unlimited)" not carry_over 100 100
check "negative plan moves towards zero" [ "$(carry_over -100 30)" = -70 ]
check "unlimited plan prints no new limit" [ "$(carry_over 0 50)" = "" ]
check "usage over a positive limit is skipped" not carry_over 100 150

HOST="1.2.3.4" KEY="k" PASS="a&b c" API_BASE=""
check "api_url adds https and port 4085, encodes creds" \
    [ "$(api_url)" = "https://1.2.3.4:4085/index.php?adminapikey=k&adminapipass=a%26b%20c" ]
HOST="http://panel.example:4084/"
check "api_url keeps http scheme and port" \
    [ "$(api_url)" = "http://panel.example:4084/index.php?adminapikey=k&adminapipass=a%26b%20c" ]
API_BASE="https://x:1/index.php?adminapikey=a&adminapipass=b"
check "api_url uses API_BASE override" [ "$(api_url)" = "$API_BASE" ]
check "response without vs is rejected" not jq -e "$JQ_VS" <<<'{"title":"x"}' 2>/dev/null
check "empty vs array is an empty list" [ "$(jq -c "$JQ_VS" <<<'{"vs":[]}')" = "{}" ]
check "is_done accepts done=1" is_done '{"done":1}'
check "is_done accepts done.done=true" is_done '{"done":{"done":true}}'
check "is_done rejects done.done=false" not is_done '{"done":{"done":false}}'

# --- End-to-end against the mock API (120 VPSes = 3 pages) ---
python3 - >"$work/state.json" <<'PY'
import json
vps = {str(i): {"vpsid": str(i), "vps_name": f"v{i}", "hostname": f"h{i}.test", "bandwidth": "500",
                "used_bandwidth": "10.75", "plid": "2", "suspended": "0"} for i in range(1, 121)}
vps["1"].update(bandwidth="1000", used_bandwidth="300.5")
vps["2"].update(bandwidth="0", used_bandwidth="50")
vps["3"].update(bandwidth="100", used_bandwidth="150")
vps["4"].update(bandwidth="-100", used_bandwidth="30")
vps["5"].update(suspended="1")
vps["6"].pop("bandwidth")
vps["8"].update(bandwidth="50", used_bandwidth="50.9")
print(json.dumps(vps))
PY
cp "$work/state.json" "$work/state.orig.json"
MOCK_FAIL_MANAGEVPS=7 python3 tests/mock_virtualizor.py "$work/state.json" "$work/port" &
mock_pid=$!
for _ in $(seq 50); do
    [[ -s $work/port ]] && break
    sleep 0.1
done

export CONFIG_FILE="$work/vps.conf" DIAG_DIR="$work"
HOST="http://127.0.0.1:$(cat "$work/port")" KEY=key PASS='p@ss&w"rd $x' API_BASE="" PARALLEL_JOBS=4
save_config
bw() { jq -r --arg id "$1" '.[$id] | "\(.used_bandwidth)/\(.bandwidth)"' "$work/state.json"; }

./reset_band.sh --dry-run >"$work/dry.out" 2>&1
check "dry run exits 1 because VPS 6 has no bandwidth field" [ $? = 1 ]
check "dry run changes nothing" cmp -s "$work/state.json" "$work/state.orig.json"
check "dry run pages through all 120 VPSes" grep -q "Processing 120 VPS" "$work/dry.out"

./reset_band.sh --dry-run 10 >"$work/one.out" 2>&1
check "single VPS search picks only VPS 10" grep -q "Processing 1 VPS" "$work/one.out"
check "single VPS dry run shows plan" grep -q "VPS 10: \[dry run\] would reset 10/500 GB -> 0/490 GB" "$work/one.out"
check "unknown VPS fails" not ./reset_band.sh --dry-run 99999 2>/dev/null
check "non-numeric VPS ID fails" not ./reset_band.sh --dry-run "1;rm" 2>/dev/null

./reset_band.sh --list-vps >"$work/list.out" 2>/dev/null
check "list-vps prints header + 120 rows" [ "$(($(wc -l <"$work/list.out")))" = 121 ]
check "list-vps marks suspended VPS" grep -q $'^5\tv5\t.*\tsuspended$' "$work/list.out"

./reset_band.sh --cron
check "cron run exits 1 when a VPS fails" [ $? = 1 ]
check "failed VPS logged with the limit to set by hand" \
    grep -q "VPS 7: usage reset but limit update failed; set its limit to 490 GB by hand" "$work/reset_band.log"
check "failed VPS keeps its old limit" [ "$(bw 7)" = "0/500" ]
check "regular plan carried over" [ "$(bw 1)" = "0/700" ]
check "unlimited plan: usage reset, limit kept" [ "$(bw 2)" = "0/0" ]
check "over-limit VPS left untouched" [ "$(bw 3)" = "150/100" ]
check "negative plan moved towards zero" [ "$(bw 4)" = "0/-70" ]
check "suspended VPS processed" [ "$(bw 5)" = "0/490" ]
check "VPS with no bandwidth field left untouched" [ "$(bw 6)" = "10.75/null" ]
check "missing field logged" grep -q "VPS 6: bandwidth, used_bandwidth or plid missing" "$work/reset_band.log"
check "usage rounding down to the limit is skipped, not made unlimited" [ "$(bw 8)" = "50.9/50" ]
check "VPS on the last page processed" [ "$(bw 120)" = "0/490" ]
check "plan ID preserved" [ "$(jq -r '.["1"].plid' "$work/state.json")" = 2 ]
check "audit log: 115 changes, 2 skips, 1 unlimited, 1 failed" [ "$(($(wc -l <"$work/reset_band_changes.log")))" = 119 ]
check "failed limit update is audited" grep -q "VPS 7  10/500 => 0/500 LIMIT UPDATE FAILED, set limit to 490 (plan 2)" "$work/reset_band_changes.log"
check "audit line format" grep -qE '^[0-9-]+ [0-9:]+  VPS 1  300/1000 => 0/700 \(plan 2\)$' "$work/reset_band_changes.log"
check "verbose log has worker output" grep -q "VPS 1: 300/1000 GB -> 0/700 GB" "$work/reset_band.log"
check "config file is private" [ "$(stat -c %a "$CONFIG_FILE" 2>/dev/null || stat -f %Lp "$CONFIG_FILE")" = 600 ]

KEY=wrong
save_config
./reset_band.sh --list-vps >/dev/null 2>"$work/bad.err"
check "bad credentials fail" [ $? != 0 ]
check "bad credentials report the API error" grep -q "Invalid API credentials" "$work/bad.err"

echo
if ((fails)); then
    echo "$fails test(s) failed"
    exit 1
fi
echo "All tests passed"
