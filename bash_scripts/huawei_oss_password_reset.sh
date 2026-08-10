#!/bin/bash
# ==============================================================
# huawei_oss_password_reset.sh
# ==============================================================
# Resets OS-level passwords on Huawei OSS nodes via SSH + expect.
# Modelled on dns_password_reset.sh (same structure, same CSV format).
#
# Called by Django as:
#   bash huawei_oss_password_reset.sh <input.csv> <output.csv>
#
# Input CSV format (tab or comma separated):
#   NodeIP  NodeType  Username  OldPassword  NewPassword
#
# Huawei OSS SSH session flow observed:
#   1. SSH connect → banner → "password:"   → send OLD password
#   2. Banner lines + shell prompt "~>"     → send "passwd"
#   3. "Current password:"                  → send OLD password
#   4. "New password:"                      → send NEW password
#   5. "Retype new password:"               → send NEW password
#   6. "successfully"                       → EXIT 0 (success)
#
# Exit codes used inside expect (same convention as project):
#   0  = success
#   10 = SSH timeout
#   11 = connection refused
#   13 = wrong old password / permission denied
#   17 = connection closed (EOF)
#   20 = passwd command failed (bad password / policy rejected)
#   21 = passwd prompt timeout
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=45

echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"

# ---- Parse input CSV (tab or comma) --------------------------
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP=$(echo "$IP" | xargs)
    [[ -z "$IP" ]] && continue
    echo "$IP|$TYPE|$USER|$OLD_PASS|$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting Huawei OSS Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
echo ">>> Logs: $LOG_DIR"
echo "====================================================================="

# ---- Core reset function -------------------------------------
process_node() {
    local LINE="$1"
    local NODE_IP=$(echo "$LINE"  | cut -d'|' -f1)
    local NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME=$(echo "$LINE"  | cut -d'|' -f3)
    local OLD_PASS=$(echo "$LINE"  | cut -d'|' -f4)
    local NEW_PASS=$(echo "$LINE"  | cut -d'|' -f5)

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}.log"
    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    # Write log header
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

            spawn ssh -o StrictHostKeyChecking=no \
                      -o UserKnownHostsFile=/dev/null \
                      -o ConnectTimeout=10 \
                      -o NumberOfPasswordPrompts=1 \
                      $USERNAME@$NODE_IP

            # -----------------------------------------------
            # STAGE 1 — SSH Login
            # Huawei OSS shows a banner then "password:"
            # -----------------------------------------------
            expect {
                -nocase "password:"             { send "$OLD_PASS\r" }
                -nocase "permission denied"     { exit 13 }
                -nocase "authentication failed" { exit 13 }
                -nocase "connection refused"    { exit 11 }
                timeout                         { exit 10 }
                eof                             { exit 17 }
            }

            # -----------------------------------------------
            # STAGE 2 — Wait for Huawei OSS shell prompt
            # Prompt ends with "~>"  e.g.  elcmadm@OSSSVRM-1:~>
            # Also accept common variants: $  #  >
            # -----------------------------------------------
            expect {
                "~>"                            { send "passwd\r" }
                -re {[\$\#>]}                   { send "passwd\r" }
                -nocase "permission denied"     { exit 13 }
                -nocase "authentication failed" { exit 13 }
                timeout                         { exit 10 }
                eof                             { exit 17 }
            }

            # -----------------------------------------------
            # STAGE 3 — OS passwd command interaction
            # -----------------------------------------------

            # Step 3a: "Current password:" — send OLD password
            expect {
                -nocase "current password:"     { send "$OLD_PASS\r" }
                -nocase "current"               { send "$OLD_PASS\r" }
                -nocase "password:"             { send "$OLD_PASS\r" }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # Step 3b: "New password:" — first entry
            expect {
                -nocase "new password:"         { send "$NEW_PASS\r" }
                -nocase "new"                   { send "$NEW_PASS\r" }
                -nocase "bad password"          { exit 20 }
                -nocase "authentication token"  { exit 20 }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # Step 3c: "Retype new password:" — confirmation
            expect {
                -nocase "retype"                { send "$NEW_PASS\r" }
                -nocase "re-enter"              { send "$NEW_PASS\r" }
                -nocase "confirm"               { send "$NEW_PASS\r" }
                -nocase "new password:"         { send "$NEW_PASS\r" }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }

            # -----------------------------------------------
            # STAGE 4 — Confirm result
            # -----------------------------------------------
            expect {
                -nocase "successfully"          { exit 0 }
                -nocase "updated"               { exit 0 }
                -nocase "changed"               { exit 0 }
                -nocase "failure"               { exit 20 }
                -nocase "unchanged"             { exit 20 }
                -nocase "bad password"          { exit 20 }
                -nocase "authentication token"  { exit 20 }
                -nocase "does not meet"         { exit 20 }
                timeout                         { exit 21 }
                eof                             { exit 17 }
            }
EOF

        RESULT_CODE=$?
        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RESULT_CODE] ---" >> "$NODE_LOG"

        case "$RESULT_CODE" in
            0)  STATUS="SUCCESS"; REASON="OS Password Updated Successfully" ;;
            10) STATUS="FAILED";  REASON="SSH Timeout" ;;
            11) STATUS="FAILED";  REASON="Connection Refused" ;;
            13) STATUS="FAILED";  REASON="Wrong Old Password / Permission Denied" ;;
            17) STATUS="FAILED";  REASON="Connection Closed (EOF)" ;;
            20) STATUS="FAILED";  REASON="passwd command failed (policy/bad password)" ;;
            21) STATUS="FAILED";  REASON="passwd prompt timeout" ;;
            *)  STATUS="FAILED";  REASON="Unexpected Error (code: $RESULT_CODE)" ;;
        esac

        echo "Final Status: $STATUS ($REASON)" >> "$NODE_LOG"
        [[ "$STATUS" == "SUCCESS" ]] && break
        ((ATTEMPT++))
    done

    # Write result row to output CSV
    echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%d-%m-%Y %H:%M')\",\"$NODE_LOG\"" >> "$OUTPUT_CSV"
    printf "[%s] Node: %-16s | Status: %-10s | Reason: %s\n" "$(date '+%T')" "$NODE_IP" "$STATUS" "$REASON"
}

# ---- Worker loop (parallel) ----------------------------------
export -f process_node
export LOG_DIR OUTPUT_CSV MAX_RETRY TIMEOUT

while read -r LINE; do
    process_node "$LINE" &
    if [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; then
        wait -n
    fi
done < "$PARSED_FILE"

wait
rm -f "$PARSED_FILE"

echo "====================================================================="
echo ">>> Done! Results: $OUTPUT_CSV"
echo ">>> Logs:          $LOG_DIR"
exit 0
