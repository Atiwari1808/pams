#!/bin/bash
# ================================
# reachability_check.sh
# ================================
# Usage: bash reachability_check.sh <input.csv> <output.csv>
# ================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps ssh
 
DEFAULT_PORT=22
SSH_TIMEOUT=5
SSH_CONNECT_TIMEOUT=5

declare -A IPV6_MAP=(
    ["150.236.11.112"]="2401:4900:24::1285"
    ["150.236.11.115"]="2401:4900:24::1298"
    ["150.236.11.134"]="2401:4900:24::1342"
    ["150.236.11.170"]="2401:4900:24::1341"
    ["150.236.11.173"]="2401:4900:24::1346"
    ["150.236.11.176"]="2401:4900:24::1347"
    ["150.236.11.198"]="2401:4900:24::1337"
    ["150.236.11.205"]="2401:4900:24::1345"
    ["150.236.11.208"]="2401:4900:24::1344"
    ["150.236.11.210"]="2401:4900:24::1290"
    ["150.236.11.43"]="2401:4900:24::1201"
    ["150.236.11.45"]="2401:4900:24::1208"
    ["150.236.17.160"]="2401:4900:24::1C20"
    ["150.236.17.161"]="2401:4900:24::1C21"
    ["150.236.17.162"]="2401:4900:24::1C22"
    ["150.236.17.163"]="2401:4900:24::1C23"
    ["150.236.17.164"]="2401:4900:24::1C24"
    ["150.236.17.166"]="2401:4900:24::1C26"
    ["150.236.17.167"]="2401:4900:24::1C27"
    ["150.236.17.168"]="2401:4900:24::1C28"
    ["150.236.17.169"]="2401:4900:24::1C29"
    ["150.236.17.187"]="2401:4900:24::1775"
    ["150.236.17.226"]="2401:4900:24::1732/1738"
    ["150.236.17.227"]="2401:4900:24::1726"
    ["150.236.17.228"]="2401:4900:24::1727"
    ["150.236.17.231"]="2401:4900:24::1774"
    ["150.236.17.239"]="2401:4900:24::1778"
    ["150.236.17.242"]="2401:4900:24::1780"
    ["150.236.17.246"]="2401:4900:24::1771"
    ["150.236.17.251"]="2401:4900:24::1770"
    ["150.236.17.38"]="2401:4900:24::1756"
    ["150.236.17.39"]="2401:4900:24::1739"
    ["150.236.17.51"]="2401:4900:24::1740"
    ["150.236.9.11"]="2401:4900:24::1048"
    ["150.236.9.15"]="2401:4900:24::1047"
    ["150.236.9.18"]="2401:4900:24::1037"
    ["150.236.9.22"]="2401:4900:24::1776"
    ["150.236.9.23"]="2401:4900:24::1046"
    ["150.236.9.24"]="2401:4900:24::1045"
    ["150.236.9.3"]="2401:4900:24::1042"
    ["150.236.9.30"]="2401:4900:24::1068"
    ["150.236.9.4"]="2401:4900:24::1010"
    ["150.236.9.5"]="2401:4900:24::1052"
    ["150.236.9.6"]="2401:4900:24::1053"
    ["150.236.9.72"]="2401:4900:24::1065"
    ["150.236.9.73"]="2401:4900:24::1066"
    ["150.236.9.74"]="2401:4900:24::1067"
    ["150.236.9.8"]="2401:4900:24::1016"
    ["150.236.9.86"]="2401:4900:24::1036"
    ["150.236.9.87"]="2401:4900:24::1035"
    ["150.236.9.88"]="2401:4900:24::1044"
    ["150.236.9.9"]="2401:4900:24::1049"
    ["150.236.9.90"]="2401:4900:24::1032"
    ["150.236.9.91"]="2401:4900:24::1031"
    ["150.236.9.97"]="2401:4900:24::1051"
    ["150.236.9.98"]="2401:4900:24::1050"
    ["150.236.9.36"]="2401:4900:24::1012"
    ["150.236.9.38"]="2401:4900:24::1014"
    ["150.236.17.165"]="2401:4900:24::1C25"
    ["150.236.10.37"]="NA"
    ["150.236.17.215"]="2401:4900:24::1798"
    ["150.236.9.28"]="2401:4900:24::1073"
)

if [[ -z "$INPUT_CSV" || -z "$OUTPUT_CSV" ]]; then
    echo "Usage: $0 <input.csv> <output.csv>" >&2; exit 1
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo "Error: Input file not found: $INPUT_CSV" >&2; exit 1
fi

# ================================
# PARSE CSV WITH CARRY-FORWARD
# ================================
declare -a RESP_IPS_ORDER
declare -A RESP_IPS_SEEN
declare -a TARGET_IPS_ORDER
declare -A TARGET_IPS_SEEN
declare -A TARGET_PORT_MAP

first_line=1
last_resp_ip=""
last_target_ip=""
current_port="$DEFAULT_PORT"

while IFS=',' read -r resp_ip target_ip port_col || [ -n "$resp_ip" ]; do
    resp_ip=$(echo "$resp_ip" | tr -d '[:space:]\r\t')
    target_ip=$(echo "$target_ip" | tr -d '[:space:]\r\t')
    port_col=$(echo "$port_col" | tr -d '[:space:]\r\t')

    if [[ $first_line -eq 1 ]]; then
        first_line=0
        [[ "$resp_ip" =~ ^[a-zA-Z] ]] && continue
    fi

    [[ -z "$resp_ip" && -z "$target_ip" ]] && continue

    # Carry forward logic
    [[ -n "$resp_ip" ]] && last_resp_ip="$resp_ip" || resp_ip="$last_resp_ip"
    [[ -n "$target_ip" ]] && last_target_ip="$target_ip" || target_ip="$last_target_ip"
    
    # Port logic
    if [[ "$port_col" =~ ^[0-9]+$ ]]; then
        current_port="$port_col"
    else
        current_port="$DEFAULT_PORT"
    fi

    if [[ -n "$resp_ip" ]]; then
        if [[ -z "${RESP_IPS_SEEN[$resp_ip]+x}" ]]; then
            RESP_IPS_SEEN[$resp_ip]=1
            RESP_IPS_ORDER+=("$resp_ip")
        fi
    fi

    if [[ -n "$target_ip" ]]; then
        if [[ -z "${TARGET_IPS_SEEN[$target_ip]+x}" ]]; then
            TARGET_IPS_SEEN[$target_ip]=1
            TARGET_IPS_ORDER+=("$target_ip")
        fi
        TARGET_PORT_MAP["$target_ip"]="$current_port"
    fi
done < "$INPUT_CSV"

echo ">>> Servers (${#RESP_IPS_ORDER[@]}): ${RESP_IPS_ORDER[*]}"
echo ">>> Targets (${#TARGET_IPS_ORDER[@]}): ${TARGET_IPS_ORDER[*]}"
echo ""

# ================================
# WRITE HEADER
# ================================
{
    printf "IPv4,IPv6"
    for t in "${TARGET_IPS_ORDER[@]}"; do printf ",%s" "$t"; done
    printf "\n"
} > "$OUTPUT_CSV"

printf "\n%-22s %-38s" "IPv4" "IPv6"
for t in "${TARGET_IPS_ORDER[@]}"; do printf " %-18s" "$t"; done
printf "\n%s\n" "$(printf '=%.0s' $(seq 1 118))"

# ================================
# REMOTE SCRIPT
# ================================
REMOTE_SCRIPT=$(cat <<'EOF'
check_reach() {
    local ip="$1"
    local port="$2"
    local timeout="$3"
    
    nc -z -w "$timeout" "$ip" "$port" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then echo "Reachable"; return; fi

    local ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=$timeout"
    local family="-4"
    [[ "$ip" == *:* ]] && family="-6"
    
    local out
    out=$(ssh $family $ssh_opts -p "$port" "$ip" exit 2>&1)
    if [[ $? -eq 0 ]] || echo "$out" | grep -qiE "Permission denied|banner|closed by remote"; then
        echo "Reachable"
    else
        echo "Unreachable"
    fi
}

targets=($TARGETS_LIST)
ports=($PORTS_LIST)
tout=$TIMEOUT
TMP_DIR=$(mktemp -d)

for idx in "${!targets[@]}"; do
    check_reach "${targets[$idx]}" "${ports[$idx]}" "$tout" > "$TMP_DIR/${idx}.txt" &
done
wait
for idx in "${!targets[@]}"; do
    res=$(cat "$TMP_DIR/${idx}.txt")
    echo "RESULT:${targets[$idx]}:$res"
done
rm -rf "$TMP_DIR"
EOF
)

# ================================
# EXECUTION LOOP
# ================================
for resp_ip in "${RESP_IPS_ORDER[@]}"; do
    ipv6="${IPV6_MAP[$resp_ip]:-N/A}"
    
    PORTS_FOR_SSH=""
    for t in "${TARGET_IPS_ORDER[@]}"; do
        PORTS_FOR_SSH+=" ${TARGET_PORT_MAP[$t]}"
    done
    PORTS_FOR_SSH="${PORTS_FOR_SSH# }"

    RESULTS=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=$SSH_CONNECT_TIMEOUT "$resp_ip" \
        "TARGETS_LIST='${TARGET_IPS_ORDER[*]}' PORTS_LIST='$PORTS_FOR_SSH' TIMEOUT=$SSH_TIMEOUT bash -s" <<< "$REMOTE_SCRIPT" 2>/dev/null)

    declare -A PARSED
    while IFS= read -r line; do
        if [[ "$line" =~ ^RESULT:(.+):(.+)$ ]]; then
            PARSED["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi
    done <<< "$RESULTS"

    # Save to CSV
    printf "%s,%s" "$resp_ip" "$ipv6" >> "$OUTPUT_CSV"
    for t in "${TARGET_IPS_ORDER[@]}"; do
        res="${PARSED[$t]:-Unreachable}"
        [[ -z "$RESULTS" ]] && res="SSH_Failed"
        printf ",%s" "$res" >> "$OUTPUT_CSV"
    done
    printf "\n" >> "$OUTPUT_CSV"

    # Console Output
    printf "%-22s %-38s" "$resp_ip" "$ipv6"
    for t in "${TARGET_IPS_ORDER[@]}"; do
        res="${PARSED[$t]:-Unreachable}"
        [[ -z "$RESULTS" ]] && res="SSH_Failed"
        printf " %-18s" "$res"
    done
    printf "\n"
done

printf '\n%s\n' "$(printf '=%.0s' $(seq 1 118))"
echo ">>> Done! Results saved to $OUTPUT_CSV"
exit 0