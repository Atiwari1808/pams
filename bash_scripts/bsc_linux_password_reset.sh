#!/usr/bin/env bash
# ==============================================================
# bsc_linux_password_reset.sh  —  PAMS Password Reset for BSC_LINUX nodes
# ==============================================================
# Called by Django as:
#   bash pw_reset_wrapper.sh bsc_linux_password_reset.sh <input.csv> <output.csv>
#
# Input CSV columns:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#   (Self-reset: login as Username with OldPassword, change to NewPassword)
#
# Node format: BSC_LINUX  (restricted '>' shell)
#   Flow (from manual reset log):
#     ssh -> banner -> Password:        (send OLD, SSH login)
#     '>' prompt      -> send "passwd"
#     Old Password:   -> send OLD
#     New password:   -> send NEW
#     Retype new password: -> send NEW
#     "Password changed." / "passwd: password updated successfully"  -> SUCCESS
#     '>' prompt      -> send "exit"
#
# Exit Codes:
#   0  = SUCCESS
#   10 = SSH Timeout / Host Unreachable
#   11 = Connection Refused
#   12 = No Route to Host
#   13 = Wrong Old Password / Auth Failed
#   17 = EOF / Connection Closed
#   20 = Shell Prompt '>' Not Received After Login
#   21 = Passwd Prompt Timeout
#   22 = BAD PASSWORD (weak / policy violation)
#   24 = New Passwords Did Not Match / Unknown Failure
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=45

# ── Output CSV header ─────────────────────────────────────────
echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"
CSV_LOCK="${OUTPUT_CSV}.lock"

# ── Parse input CSV into pipe-delimited temp file ─────────────
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | \
while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP=$(echo "$IP" | xargs)
    [[ -z "$IP" ]] && continue
    printf '%s|%s|%s|%s|%s\n' "$IP" "$TYPE" "$USER" "$OLD_PASS" "$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting BSC_LINUX Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
echo ">>> Detailed node logs: $LOG_DIR"
echo "====================================================================="

# ==============================================================
# CORE PASSWORD RESET FUNCTION
# ==============================================================
process_node() {
    local LINE="$1"
    local NODE_IP;   NODE_IP=$(echo "$LINE"   | cut -d'|' -f1)
    local NODE_TYPE; NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME;  USERNAME=$(echo "$LINE"  | cut -d'|' -f3)
    local OLD_PASS;  OLD_PASS=$(echo "$LINE"  | cut -d'|' -f4)
    local NEW_PASS;  NEW_PASS=$(echo "$LINE"  | cut -d'|' -f5)

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}_${USERNAME}.log"
    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    {
        echo "=================================================="
        echo " BSC_LINUX NODE PASSWORD RESET LOG"
        echo "=================================================="
        echo " Node IP   : $NODE_IP"
        echo " Node Type : $NODE_TYPE"
        echo " Username  : $USERNAME"
        echo " Time      : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        local TCL_SCRIPT
        TCL_SCRIPT=$(mktemp /tmp/bsc_linux_XXXXXX.tcl)

        # Part 1: bash injects values as Tcl literals in {curly braces}
        # Curly braces = fully literal in Tcl -> safe for $, [, \, ", { }, space
        cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_user     {${USERNAME}}
set t_node_ip  {${NODE_IP}}
set t_old_pass {${OLD_PASS}}
set t_new_pass {${NEW_PASS}}
set t_timeout  ${TIMEOUT}
VAR_BLOCK

        # Part 2: static Tcl/expect logic — bash never touches this block
        cat >> "$TCL_SCRIPT" <<'TCLEOF'
set timeout $t_timeout
log_user 1

# ── STAGE 1: SSH login as target user ─────────────────────────
# Restricted-shell nodes need a PTY, so NO -T here.
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_user@$t_node_ip

# Banner text is absorbed; wait for the SSH login "Password:" prompt.
expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    -nocase "password:"             { send "$t_old_pass\r" }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── STAGE 2: Restricted shell '>' prompt -> send "passwd" ─────
# The prompt is a bare '>' (optionally preceded by control chars/newline).
expect {
    -nocase "permission denied"     { exit 13 }
    -nocase "incorrect password"    { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -re {>\s*$}                     { send "passwd\r" }
    timeout                         { exit 20 }
    eof                             { exit 17 }
}

# ── STAGE 3: Old Password prompt ─────────────────────────────
expect {
    -nocase "old password:"         { send "$t_old_pass\r" }
    -nocase "current password:"     { send "$t_old_pass\r" }
    -nocase "bad password"          { exit 22 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# ── STAGE 4: New password prompt ─────────────────────────────
expect {
    -nocase "new password:"         { send "$t_new_pass\r" }
    -nocase "bad password"          { exit 22 }
    -nocase "authentication token"  { exit 13 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# ── STAGE 5: Retype / confirm new password ───────────────────
expect {
    -nocase "retype new password:"  { send "$t_new_pass\r" }
    -nocase "re-enter new password:" { send "$t_new_pass\r" }
    -nocase "confirm new password:" { send "$t_new_pass\r" }
    -nocase "bad password"          { exit 22 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# ── STAGE 6: Verify result ───────────────────────────────────
expect {
    -nocase "password updated successfully" { send "exit\r"; exit 0 }
    -nocase "password changed"              { send "exit\r"; exit 0 }
    -nocase "successfully"                  { send "exit\r"; exit 0 }
    -nocase "do not match"                  { exit 24 }
    -nocase "passwords do not"              { exit 24 }
    -nocase "bad password"                  { exit 22 }
    -nocase "not changed"                   { exit 24 }
    -nocase "error"                         { exit 24 }
    timeout                                 { exit 21 }
    eof                                     { exit 17 }
}
TCLEOF

        expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
        local RC=$?
        rm -f "$TCL_SCRIPT"

        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RC] ---" >> "$NODE_LOG"

        case "$RC" in
        0)  STATUS="SUCCESS"; REASON="Password Updated Successfully";;
        10) STATUS="FAILED";  REASON="SSH Timeout / Host Unreachable";;
        11) STATUS="FAILED";  REASON="Connection Refused";;
        12) STATUS="FAILED";  REASON="No Route to Host";;
        13) STATUS="FAILED";  REASON="Wrong Old Password (Auth Failed)";;
        17) STATUS="FAILED";  REASON="Connection Closed Unexpectedly (EOF)";;
        20) STATUS="FAILED";  REASON="Shell Prompt '>' Not Received After Login";;
        21) STATUS="FAILED";  REASON="Passwd Prompt Timeout";;
        22) STATUS="FAILED";  REASON="BAD PASSWORD (Weak / Policy Violation)";;
        24) STATUS="FAILED";  REASON="New Passwords Did Not Match / Unknown Failure";;
        *)  STATUS="FAILED";  REASON="Unexpected Error (Code: $RC)";;
        esac

        echo "Final Status: $STATUS ($REASON)" >> "$NODE_LOG"

        [[ "$STATUS" == "SUCCESS" ]] && break
        [[ "$RC" == "13" || "$RC" == "22" ]] && break
        ((ATTEMPT++))
        [[ $ATTEMPT -le $MAX_RETRY ]] && echo "Retrying in 5s..." >> "$NODE_LOG" && sleep 5
    done

    # Thread-safe write to output CSV
    (
        flock -w 10 200
        echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" >> "$OUTPUT_CSV"
    ) 200>"$CSV_LOCK"

    printf "[%s] Node: %-24s | User: %-12s | Status: %-8s | %s\n" \
        "$(date '+%T')" "$NODE_IP" "$USERNAME" "$STATUS" "$REASON"
}

# ==============================================================
# PARALLEL WORKER LOOP
# ==============================================================
export -f process_node
export LOG_DIR OUTPUT_CSV CSV_LOCK TIMEOUT MAX_RETRY

while read -r LINE; do
    process_node "$LINE" &
    while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; do
        wait -n 2>/dev/null || sleep 1
    done
done < "$PARSED_FILE"

wait
rm -f "$PARSED_FILE" "$CSV_LOCK"

echo "====================================================================="
echo ">>> Done! Results written to : $OUTPUT_CSV"
echo ">>> Full Execution Logs in   : $LOG_DIR"
exit 0

