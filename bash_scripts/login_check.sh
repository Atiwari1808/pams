#!/bin/bash
# ================================
# login_check.sh (Django Integrated with Detailed Logging & Custom Port Support)
# ================================
# Called by Django as:
#   bash login_check.sh <input.csv> <output.csv>
#
# FIX 1: Strip surrounding quotes from CSV fields after parsing
# FIX 2: Passwords passed as Tcl {literal} vars � safe for special
#         chars like  $ [ \ " { }  (e.g. "Calcium$321")
# FIX 3: Port handled in bash, not passed into Tcl, so empty port
#         never causes "extra characters after close-quote" in spawn
# ================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh
 
MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=30

echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"

# ================================
# HELPER: strip surrounding double-quotes from a value
# e.g.  "WMG"  ?  WMG
# ================================
strip_quotes() {
    local val="$1"
    # Remove a leading " and a trailing " if both present
    if [[ "$val" == '"'*'"' ]]; then
        val="${val#\"}"
        val="${val%\"}"
    fi
    echo "$val"
}

# ================================
# PARSE INPUT CSV
# ================================
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

# Read 5 columns: IP | TYPE | USER | PASS | PORT
# strip_quotes handles fields that were quoted in the CSV
tail -n +2 "$INPUT_CSV" | tr -d '\r' | while IFS="$DELIM" read -r IP TYPE USER PASS PORT _REST; do
    IP=$(strip_quotes   "$(echo "$IP"   | xargs)")
    TYPE=$(strip_quotes "$(echo "$TYPE" | xargs)")
    USER=$(strip_quotes "$(echo "$USER" | xargs)")
    PASS=$(strip_quotes "$(echo "$PASS" | xargs)")
    PORT=$(strip_quotes "$(echo "$PORT" | xargs)")
    [[ -z "$IP" ]] && continue
    # Use a safer delimiter (pipe) to store; pipe is illegal in IPs/usernames
    printf '%s|%s|%s|%s|%s\n' "$IP" "$TYPE" "$USER" "$PASS" "$PORT" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting Login Check for $TOTAL_NODES nodes"
echo ">>> Detailed node logs will be saved to: $LOG_DIR"
echo "====================================================================="

# ================================
# CORE LOGIN CHECK FUNCTION
# ================================
process_node() {
    local LINE="$1"
    local NODE_IP=$(echo "$LINE"   | cut -d'|' -f1)
    local NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME=$(echo "$LINE"  | cut -d'|' -f3)
    local PASSWORD=$(echo "$LINE"  | cut -d'|' -f4)
    local NODE_PORT=$(echo "$LINE" | cut -d'|' -f5)

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}.log"

    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    # -- Port handling (pure bash, never passed into Tcl spawn string) --
    local SSH_PORT="22"
    local LOG_PORT="22 (Default)"
    if [[ -n "$NODE_PORT" && "$NODE_PORT" =~ ^[0-9]+$ ]]; then
        SSH_PORT="$NODE_PORT"
        LOG_PORT="$NODE_PORT"
    fi

    {
        echo "=================================================="
        echo " SSH LOGIN EXECUTION LOG"
        echo "=================================================="
        echo " Node IP  : $NODE_IP"
        echo " Port     : $LOG_PORT"
        echo " Type     : $NODE_TYPE"
        echo " User     : $USERNAME"
        echo " Time     : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        # ----------------------------------------------------------
        # THE FIX:
        # Build a temp Tcl script in two parts:
        #
        # Part 1 (VAR_BLOCK � bash-expanded heredoc):
        #   Bash writes USERNAME, NODE_IP, PASSWORD, SSH_PORT into
        #   Tcl "set" statements wrapped in {curly braces}.
        #   Tcl {} = fully literal � $ [ \ " space are all safe.
        #
        # Part 2 (TCLEOF � single-quoted heredoc):
        #   Bash does NOT expand anything here.
        #   Tcl uses the $t_* variables set in Part 1.
        #   "spawn ssh -p $t_port ..." ? Tcl sees a clean integer,
        #   never an empty string or quoted value.
        # ----------------------------------------------------------
        local TCL_SCRIPT
        TCL_SCRIPT=$(mktemp /tmp/login_check_XXXXXX.tcl)

        # Part 1: inject bash values as safe Tcl literals
        cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_user     {${USERNAME}}
set t_node_ip  {${NODE_IP}}
set t_password {${PASSWORD}}
set t_port     {${SSH_PORT}}
set t_timeout  ${TIMEOUT}
VAR_BLOCK

        # Part 2: static Tcl/expect logic � bash never touches this
        cat >> "$TCL_SCRIPT" <<'TCLEOF'

set timeout $t_timeout
log_user 1

# spawn uses $t_port (always a clean integer, e.g. "22")
spawn ssh -p $t_port \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_user@$t_node_ip

expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "password:" {
        send $t_password\r
        exp_continue
    }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    -re {[$>#%]}                    { send "exit\r"; exit 0 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}
TCLEOF

        expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
        RESULT_CODE=$?
        rm -f "$TCL_SCRIPT"

        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RESULT_CODE] ---" >> "$NODE_LOG"

        case "$RESULT_CODE" in
            0)  STATUS="LOGIN_OK"; REASON="Success";;
            10) STATUS="FAILED";   REASON="Timeout";;
            11) STATUS="FAILED";   REASON="Connection Refused";;
            12) STATUS="FAILED";   REASON="No Route to Host";;
            13) STATUS="FAILED";   REASON="Wrong Password / Auth Failed";;
            17) STATUS="FAILED";   REASON="Connection Closed (EOF)";;
            *)  STATUS="FAILED";   REASON="Unexpected Error (Code $RESULT_CODE)";;
        esac

        echo "Final Status: $STATUS ($REASON)" >> "$NODE_LOG"
        [[ "$STATUS" == "LOGIN_OK" ]] && break
        ((ATTEMPT++))
    done

    echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" >> "$OUTPUT_CSV"

    printf "[%s] Node: %-16s | Port: %-5s | Status: %-10s | Reason: %s\n" \
        "$(date '+%T')" "$NODE_IP" "$LOG_PORT" "$STATUS" "$REASON"
}

# ================================
# WORKER LOOP
# ================================
export -f process_node
export LOG_DIR OUTPUT_CSV TIMEOUT MAX_RETRY

while read -r LINE; do
    process_node "$LINE" &
    if [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; then
        wait -n
    fi
done < "$PARSED_FILE"

wait
rm -f "$PARSED_FILE"

echo "====================================================================="
echo ">>> Done! Results written to: $OUTPUT_CSV"
echo ">>> Full Execution Logs in:   $LOG_DIR"
exit 0