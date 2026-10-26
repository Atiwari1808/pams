#!/usr/bin/env bash
# cmg_password_reset.sh  —  PAMS Password Reset for Nokia 7750 SR-MG (CMG / TiMOS SR OS)
# ==============================================================
# Node Type : CMG (Nokia 7750 SR-MG — TiMOS-MG / SR OS)
# Called by : bash pw_reset_wrapper.sh cmg_password_reset.sh <input.csv> <output.csv>
#
# Input CSV columns:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#   (Self-reset: login as Username with OldPassword, change to NewPassword)
#
# Flow — both cases converge on the 3-prompt sequence:
#     Enter current password:  ->  OLD
#     Enter new password:       ->  NEW
#     Re-enter new password:    ->  NEW
#
#   PATH A (expired):     "You need to change your password." appears right
#                         after login -> current-password prompt is automatic.
#   PATH B (not expired): SR OS prompt reached -> send "password" -> prompts appear.
#
# Exit Codes:
#   0  = SUCCESS
#   10 = SSH Timeout
#   11 = Connection Refused
#   12 = No Route to Host
#   13 = Wrong Old Password / Auth Failed
#   17 = EOF / Connection Closed
#   20 = New Password Rejected (bad/weak/policy)
#   21 = Prompt reached but 'password' command gave no prompt
#   22 = New Passwords Did Not Match
#   61 = Password-Change Prompt Timeout
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=60          # SR OS prints a large EULA banner; keep generous

# ── Output CSV header ─────────────────────────────────────────
echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"

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
echo ">>> Starting CMG (Nokia SR-MG) Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
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
        echo " CMG (Nokia 7750 SR-MG) PASSWORD RESET LOG"
        echo "=================================================="
        echo " Node IP     : $NODE_IP"
        echo " Node Type   : $NODE_TYPE"
        echo " Username    : $USERNAME"
        echo " Time        : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        local TCL_SCRIPT
        TCL_SCRIPT=$(mktemp /tmp/cmg_XXXXXX.tcl)

        # Part 1: bash injects values as Tcl literals in {curly braces}
        # Curly braces = fully literal in Tcl -> safe for $, [, \, ", { }, space
        cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_node_ip  {${NODE_IP}}
set t_user     {${USERNAME}}
set t_old_pass {${OLD_PASS}}
set t_new_pass {${NEW_PASS}}
set t_timeout  ${TIMEOUT}
VAR_BLOCK

        # Part 2: static Tcl/expect logic — bash never touches this block
        cat >> "$TCL_SCRIPT" <<'TCLEOF'
set timeout $t_timeout
log_user 1

# ── STAGE 1: SSH login as target user ─────────────────────────
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_user@$t_node_ip

expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "password:"             { send "$t_old_pass\r" }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── STAGE 2: GATE — decide PATH A (expired) vs PATH B (prompt) ─
# PATH A: "You need to change your password." -> "Enter current password:" (auto)
# PATH B: SR OS prompt *A:HOST# / A:HOST#     -> send "password" to trigger prompts
set sent_pw_cmd 0
expect {
    -nocase "you need to change your password" { exp_continue }
    -nocase "enter current password:"          { send "$t_old_pass\r" }
    -nocase "current password:"                { send "$t_old_pass\r" }
    -re {\*?[AB]:\S+#\s*$} {
        if {$sent_pw_cmd == 0} {
            set sent_pw_cmd 1
            send "password\r"
            exp_continue
        } else {
            # Returned to prompt without prompting for a password — unexpected
            exit 21
        }
    }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── STAGE 3: Enter new password ───────────────────────────────
expect {
    -nocase "enter new password:"   { send "$t_new_pass\r" }
    -nocase "new password:"         { send "$t_new_pass\r" }
    -nocase "bad password"          { exit 20 }
    -nocase "current password:"     { send "$t_old_pass\r"; exp_continue }
    timeout                         { exit 61 }
    eof                             { exit 17 }
}

# ── STAGE 4: Re-enter / confirm new password ──────────────────
expect {
    -nocase "re-enter new password:" { send "$t_new_pass\r" }
    -nocase "reenter new password:"  { send "$t_new_pass\r" }
    -nocase "confirm new password:"  { send "$t_new_pass\r" }
    -nocase "retype new password:"   { send "$t_new_pass\r" }
    -nocase "bad password"           { exit 20 }
    -nocase "do not match"           { exit 22 }
    timeout                          { exit 61 }
    eof                              { exit 17 }
}

# ── STAGE 5: Confirm result — success = SR OS prompt returns ──
expect {
    -nocase "do not match"          { exit 22 }
    -nocase "not match"             { exit 22 }
    -nocase "bad password"          { exit 20 }
    -nocase "password is not"       { exit 20 }
    -nocase "does not meet"         { exit 20 }
    -nocase "minimum"               { exit 20 }
    -nocase "invalid"               { exit 20 }
    -nocase "failed"                { exit 20 }
    -re {\*?[AB]:\S+#\s*$}          { send "logout\r"; exit 0 }
    timeout                         { exit 61 }
    eof                             { exit 0 }
}
TCLEOF

        expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
        local RC=$?
        rm -f "$TCL_SCRIPT"

        echo "" >> "$NODE_LOG"
        echo "--- [Exit Code: $RC] ---" >> "$NODE_LOG"

        if [[ $RC -eq 0 ]]; then
            STATUS="SUCCESS"
            REASON="Password Changed Successfully"
            echo "Final Status: SUCCESS" >> "$NODE_LOG"
            break
        else
            case "$RC" in
            10) REASON="SSH Timeout — Host Unreachable";;
            11) REASON="Connection Refused";;
            12) REASON="No Route to Host";;
            13) REASON="Wrong Old Password / Auth Failed";;
            17) REASON="Connection Closed Unexpectedly";;
            20) REASON="New Password Rejected (bad/weak/policy)";;
            21) REASON="Prompt reached but 'password' command gave no prompt";;
            22) REASON="New Passwords Did Not Match";;
            61) REASON="Password-Change Prompt Timeout";;
             *) REASON="Unexpected Error (exit code: $RC)";;
            esac
            echo "Final Status: FAILED ($REASON)" >> "$NODE_LOG"
            break
        fi
    done

    echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" \
        >> "$OUTPUT_CSV"

    printf "[%s] Node: %-24s | User: %-12s | Status: %-10s | Reason: %s\n" \
        "$(date '+%T')" "$NODE_IP" "$USERNAME" "$STATUS" "$REASON"
}

# ==============================================================
# PARALLEL WORKER LOOP
# ==============================================================
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

