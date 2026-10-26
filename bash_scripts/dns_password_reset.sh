#!/bin/bash
# ==============================================================
# password_reset.sh (Django Integrated & Automated)
# ==============================================================
# Called by Django as:
#   bash password_reset.sh <input.csv> <output.csv>
#
# Input CSV Format:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh
 
MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=45

# Initialize CSV immediately
echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"

# ================================
# PARSE INPUT CSV
# ================================
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

# Read 5 columns: IP | TYPE | USER | OLD_PASS | NEW_PASS
tail -n +2 "$INPUT_CSV" | tr -d '\r' | while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP=$(echo "$IP" | xargs)
    [[ -z "$IP" ]] && continue
    echo "$IP|$TYPE|$USER|$OLD_PASS|$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting Password Reset for $TOTAL_NODES nodes (Parallel: $MAX_PARALLEL)"
echo ">>> Detailed node logs will be saved to: $LOG_DIR"
echo "====================================================================="

# ================================
# CORE PASSWORD RESET FUNCTION
# ================================
process_node() {
    local LINE="$1"
    local NODE_IP=$(echo "$LINE" | cut -d'|' -f1)
    local NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME=$(echo "$LINE" | cut -d'|' -f3)
    local OLD_PASS=$(echo "$LINE" | cut -d'|' -f4)
    local NEW_PASS=$(echo "$LINE" | cut -d'|' -f5)

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}.log"

    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    {
        echo "=================================================="
        echo " SSH PASSWORD RESET LOG"
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

        expect <<EOF >> "$NODE_LOG" 2>&1
            set timeout $TIMEOUT
            log_user 1

            spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 $USERNAME@$NODE_IP

            # --- STAGE 1: INITIAL LOGIN ---
            # Step 1a: Send old password at the SSH login prompt
            expect {
                -nocase "password:"             { send "$OLD_PASS\r" }
                -nocase "permission denied"     { exit 13 }
                -nocase "authentication failed" { exit 13 }
                -nocase "connection refused"    { exit 11 }
                timeout                         { exit 10 }
                eof                             { exit 17 }
            }

            # Step 1b: Wait for shell prompt after login, then send passwd command
            expect {
                -re {[\$>\#%]}                  { send "passwd\r" }
                -nocase "permission denied"     { exit 13 }
                -nocase "authentication failed" { exit 13 }
                timeout                         { exit 10 }
                eof                             { exit 17 }
            }

            # --- STAGE 2: OS PASSWORD UPDATE (passwd) ---
            # Step 2a: Handle current password prompt
            # Covers: "current password:", "(current) UNIX password:", plain "Password:"
            expect {
                -nocase "current"               { send "$OLD_PASS\r" }
                -nocase "unix password"         { send "$OLD_PASS\r" }
                -nocase "password:"             { send "$OLD_PASS\r" }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # Step 2b: Send new password (first prompt)
            expect {
                -nocase "new password:"         { send "$NEW_PASS\r" }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # Step 2c: Send new password again (retype/reenter prompt)
            expect {
                -nocase "new password:"         { send "$NEW_PASS\r" }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # Step 2d: Confirm success or failure of passwd command
            expect {
                -nocase "successfully"          { send "sudo ipwcli\r" }
                -nocase "updated"               { send "sudo ipwcli\r" }
                -nocase "failure"               { exit 20 }
                -nocase "unchanged"             { exit 20 }
                -nocase "bad password"          { exit 20 }
                -nocase "authentication token"  { exit 20 }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # --- STAGE 3: IPWORKS PASSWORD UPDATE (ipwcli) ---
            # Step 3a: Handle ipwcli login prompt (login: first, then password:)
            expect {
                -nocase "login:"                { send "$USERNAME\r" }
                -nocase "password"              { send "$NEW_PASS\r"; exp_continue }
                timeout                         { exit 31 }
                eof                             { exit 17 }
            }

            # Step 3b: ipwcli password prompt (uses OLD password for app login)
            expect {
                -nocase "password:"             { send "$OLD_PASS\r" }
                timeout                         { exit 31 }
                eof                             { exit 17 }
            }

            # Step 3c: Wait for IPWorks shell prompt
            expect {
                "IPWorks>"                      { send "chang pass\r" }
                timeout                         { exit 31 }
                eof                             { exit 17 }
            }

            # Step 3d: Old password prompt inside chang pass
            expect {
                -nocase "old password:"         { send "$OLD_PASS\r" }
                timeout                         { exit 30 }
                eof                             { exit 17 }
            }

            # Step 3e: New password prompt (first)
            expect {
                -nocase "new password:"         { send "$NEW_PASS\r" }
                timeout                         { exit 30 }
                eof                             { exit 17 }
            }

            # Step 3f: Confirm new password prompt
            expect {
                -nocase "confirm"               { send "$NEW_PASS\r" }
                timeout                         { exit 30 }
                eof                             { exit 17 }
            }

            # Step 3g: Confirm success and exit
            expect {
                -nocase "object(s) were updated" { send "exit\r"; exit 0 }
                -nocase "updated"               { send "exit\r"; exit 0 }
                -nocase "successfully"          { send "exit\r"; exit 0 }
                timeout                         { exit 30 }
                eof                             { exit 17 }
            }
EOF

        RESULT_CODE=$?
        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RESULT_CODE] ---" >> "$NODE_LOG"

        case "$RESULT_CODE" in
            0)  STATUS="SUCCESS"; REASON="OS & App Password Updated";;
            10) STATUS="FAILED";  REASON="SSH Timeout";;
            11) STATUS="FAILED";  REASON="Connection Refused";;
            13) STATUS="FAILED";  REASON="Wrong Old Password / Permission Denied";;
            17) STATUS="FAILED";  REASON="Connection Closed (EOF)";;
            20) STATUS="FAILED";  REASON="OS passwd command failed";;
            21) STATUS="FAILED";  REASON="OS passwd prompt timeout";;
            30) STATUS="FAILED";  REASON="IPWorks password update failed";;
            31) STATUS="FAILED";  REASON="IPWorks CLI login timeout";;
            *)  STATUS="FAILED";  REASON="Unexpected Error (code: $RESULT_CODE)";;
        esac

        echo "Final Status: $STATUS ($REASON)" >> "$NODE_LOG"

        [[ "$STATUS" == "SUCCESS" ]] && break
        ((ATTEMPT++))
    done

    # Write Result directly to the Output CSV
    echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" >> "$OUTPUT_CSV"

    printf "[%s] Node: %-16s | Status: %-10s | Reason: %s\n" "$(date '+%T')" "$NODE_IP" "$STATUS" "$REASON"
}

# ================================
# WORKER LOOP
# ================================
export -f process_node

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