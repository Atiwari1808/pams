#!/bin/bash
# ==============================================================
# wmg_password_reset.sh (Django Integrated & Automated)
# ==============================================================
# Called by Django as:
#   bash wmg_password_reset.sh <input.csv> <output.csv>
#
# Input CSV Format:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#
# WMG Node Flow (Ericsson IPOS shell):
#   1. SSH login              -> send OldPassword
#   2. Wait for IPOS prompt # -> send "change-password"
#   3. "Current password:"   -> send OldPassword
#   4. "New password:"        -> send NewPassword
#   5. "Retype new password:" -> send NewPassword
#   6. Confirm success        -> exit 0
#
# ROOT CAUSE FIX for "can't read $VAR: no such variable":
#   Passwords are written into a temp Tcl file as Tcl variables
#   inside {curly braces} BEFORE expect runs. Tcl curly braces
#   are fully literal - special chars $ [ \ { } space are safe.
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=45

echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"

PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP=$(echo "$IP" | xargs)
    [[ -z "$IP" ]] && continue
    echo "$IP|$TYPE|$USER|$OLD_PASS|$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting WMG Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
echo ">>> Logs: $LOG_DIR"
echo "====================================================================="

process_node() {
    local LINE="$1"
    local NODE_IP=$(echo "$LINE"   | cut -d'|' -f1)
    local NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME=$(echo "$LINE"  | cut -d'|' -f3)
    local OLD_PASS=$(echo "$LINE"  | cut -d'|' -f4)
    local NEW_PASS=$(echo "$LINE"  | cut -d'|' -f5)

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}_${USERNAME}.log"
    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    {
        echo "=================================================="
        echo " WMG SSH PASSWORD RESET LOG"
        echo "=================================================="
        echo " Node IP  : $NODE_IP"
        echo " Type     : $NODE_TYPE"
        echo " User     : $USERNAME"
        echo " Time     : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        # -- THE FIX ----------------------------------------------
        # Write a temp Tcl/expect script. Bash expands shell vars
        # into Tcl "set" statements wrapped in {curly braces}.
        # Tcl curly braces = fully literal string � no substitution.
        # So passwords containing  $ [ \ " space  are 100% safe.
        # ---------------------------------------------------------
        local TCL_SCRIPT
        TCL_SCRIPT=$(mktemp /tmp/wmg_expect_XXXXXX.tcl)

        # Part 1: variable declarations (bash expands values here)
        cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_user     {${USERNAME}}
set t_node_ip  {${NODE_IP}}
set t_old_pass {${OLD_PASS}}
set t_new_pass {${NEW_PASS}}
set t_timeout  ${TIMEOUT}
VAR_BLOCK

        # Part 2: static expect logic (single-quoted = bash hands
        # it to Tcl verbatim; Tcl uses $t_* vars set above)
        cat >> "$TCL_SCRIPT" <<'TCLEOF'

set timeout $t_timeout
log_user 1

# STAGE 1: SSH LOGIN
spawn ssh -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -o NumberOfPasswordPrompts=1 \
          $t_user@$t_node_ip

expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "password:"             { send $t_old_pass\r }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# STAGE 2: WAIT FOR ERICSSON IPOS SHELL PROMPT  [local]NODE#
expect {
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -re {#\s*$}                     { send "change-password\r" }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# STAGE 3: change-password dialogue

# 3a: Current password
expect {
    -nocase "current password:"     { send $t_old_pass\r }
    timeout                         { exit 30 }
    eof                             { exit 17 }
}

# 3b: New password
expect {
    -nocase "new password:"         { send $t_new_pass\r }
    -nocase "bad password"          { exit 20 }
    -nocase "password unchanged"    { exit 20 }
    timeout                         { exit 30 }
    eof                             { exit 17 }
}

# 3c: Retype new password
expect {
    -nocase "retype new password:"  { send $t_new_pass\r }
    -nocase "bad password"          { exit 20 }
    -nocase "password unchanged"    { exit 20 }
    -nocase "do not match"          { exit 21 }
    timeout                         { exit 30 }
    eof                             { exit 17 }
}

# STAGE 4: Confirm result
# Success  -> IPOS returns to prompt (#)
# Failures -> "Sorry, passwords do not match"
#             "BAD PASSWORD: The password is the same as the old one"
#             "Password unchanged" / "Cannot get the password"
expect {
    -nocase "sorry"                 { exit 21 }
    -nocase "do not match"          { exit 21 }
    -nocase "bad password"          { exit 20 }
    -nocase "password unchanged"    { exit 20 }
    -nocase "cannot get"            { exit 20 }
    -re {#\s*$}                     { send "exit\r"; exit 0 }
    timeout                         { exit 30 }
    eof                             { exit 0 }
}
TCLEOF

        expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
        RESULT_CODE=$?
        rm -f "$TCL_SCRIPT"

        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RESULT_CODE] ---" >> "$NODE_LOG"

        case "$RESULT_CODE" in
            0)  STATUS="SUCCESS"; REASON="WMG Password Changed Successfully";;
            10) STATUS="FAILED";  REASON="SSH Timeout / Host Unreachable";;
            11) STATUS="FAILED";  REASON="Connection Refused";;
            12) STATUS="FAILED";  REASON="No Route to Host";;
            13) STATUS="FAILED";  REASON="Wrong Old Password / Permission Denied";;
            17) STATUS="FAILED";  REASON="Connection Closed Unexpectedly (EOF)";;
            20) STATUS="FAILED";  REASON="Password Rejected (bad/same/policy violation)";;
            21) STATUS="FAILED";  REASON="Retype Mismatch � passwords did not match";;
            30) STATUS="FAILED";  REASON="change-password Prompt Timeout";;
            *)  STATUS="FAILED";  REASON="Unexpected Error (exit code: $RESULT_CODE)";;
        esac

        echo "Final Status: $STATUS ($REASON)" >> "$NODE_LOG"
        [[ "$STATUS" == "SUCCESS" ]] && break
        ((ATTEMPT++))
    done

    echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" >> "$OUTPUT_CSV"

    printf "[%s] Node: %-20s | User: %-12s | Status: %-10s | Reason: %s\n" \
        "$(date '+%T')" "$NODE_IP" "$USERNAME" "$STATUS" "$REASON"
}

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
echo ">>> Done! Results written to : $OUTPUT_CSV"
echo ">>> Full Execution Logs in   : $LOG_DIR"
exit 0