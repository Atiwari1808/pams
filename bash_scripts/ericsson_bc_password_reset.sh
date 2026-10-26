#!/usr/bin/env bash
# ==============================================================
# ericsson_bc_password_reset.sh
# ==============================================================
# PAMS password reset script for Ericsson BC nodes
#
# Called by:
#   bash pw_reset_wrapper.sh ericsson_bc_password_reset.sh <input.csv> <output.csv>
#
# Input CSV:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#
# Notes:
#   - SSH port is fixed: 4422
#   - Password change command is fixed: pwdmodtsuser
#   - If Username is blank, defaults to: ts_acebharti
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh flock

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=45
DEFAULT_USER="ts_acebharti"
SSH_PORT=4422
CHANGE_CMD="pwdmodtsuser"

echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"
CSV_LOCK="${OUTPUT_CSV}.lock"

# ================================
# PARSE INPUT CSV
# ================================
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP="$(echo "$IP" | xargs)"
    TYPE="$(echo "$TYPE" | xargs)"
    [[ -z "$IP" ]] && continue
    printf '%s|%s|%s|%s|%s\n' "$IP" "$TYPE" "$USER" "$OLD_PASS" "$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting Ericsson BC Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
echo ">>> Logs: $LOG_DIR"
echo "====================================================================="

# ================================
# SINGLE NODE PASSWORD RESET
# ================================
run_bc_reset() {
    local NODE_IP="$1"
    local USERNAME="$2"
    local OLD_PASS="$3"
    local NEW_PASS="$4"
    local NODE_LOG="$5"

    local TCL_SCRIPT
    TCL_SCRIPT=$(mktemp /tmp/ericsson_bc_XXXXXX.tcl)

    cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_user      {${USERNAME}}
set t_node_ip   {${NODE_IP}}
set t_old_pass  {${OLD_PASS}}
set t_new_pass  {${NEW_PASS}}
set t_timeout   ${TIMEOUT}
set t_port      ${SSH_PORT}
set t_cmd       {${CHANGE_CMD}}
VAR_BLOCK

    cat >> "$TCL_SCRIPT" <<'TCLEOF'
set timeout $t_timeout
log_user 1

# Prompt variants seen:
#   APBCL01-SC-2-2:$
#   APBCL01-SC-2-2:\x03$
#   \x03$
set prompt_host_re {[A-Za-z0-9_.:/-]+:\x03?\$ ?$}
set prompt_dollar_re {\x03?\$ ?$}

spawn ssh -p $t_port \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_user@$t_node_ip

# ------------------------------------------------------------
# STAGE 1: initial ssh login
# ------------------------------------------------------------
expect {
    -nocase "are you sure you want to continue connecting" {
        send "yes\r"
        exp_continue
    }
    -nocase "yes/no" {
        send "yes\r"
        exp_continue
    }
    -nocase "fingerprint" {
        send "yes\r"
        exp_continue
    }
    -nocase "password:" {
        send "$t_old_pass\r"
    }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -nocase "access denied"         { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ------------------------------------------------------------
# STAGE 2: wait for shell prompt after login
# ------------------------------------------------------------
expect {
    -nocase "warning: your password will expire in" { exp_continue }
    -re $prompt_host_re {}
    -re $prompt_dollar_re {}
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -nocase "access denied"         { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 20 }
    eof                             { exit 17 }
}

# ------------------------------------------------------------
# STAGE 3: run password change command
# ------------------------------------------------------------
send "$t_cmd\r"

# ------------------------------------------------------------
# STAGE 4: old password prompt
# ------------------------------------------------------------
expect {
    -nocase "old password:" { send "$t_old_pass\r" }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -nocase "access denied"         { exit 13 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# ------------------------------------------------------------
# STAGE 5: new password prompt
# ------------------------------------------------------------
expect {
    -nocase "new password:" { send "$t_new_pass\r" }
    -nocase "bad password"  { exit 22 }
    -nocase "error"         { exit 24 }
    timeout                 { exit 21 }
    eof                     { exit 17 }
}

# ------------------------------------------------------------
# STAGE 6: retype prompt
# ------------------------------------------------------------
expect {
    -nocase "retype new password:" { send "$t_new_pass\r" }
    -nocase "passwords do not match" { exit 24 }
    -nocase "do not match"           { exit 24 }
    -nocase "bad password"           { exit 22 }
    -nocase "error"                  { exit 24 }
    timeout                          { exit 21 }
    eof                              { exit 17 }
}

# ------------------------------------------------------------
# STAGE 7: verify success / prompt return
# ------------------------------------------------------------
set saw_success 0
expect {
    -nocase "password changed" {
        set saw_success 1
        exp_continue
    }
    -nocase "passwd: password updated successfully" {
        set saw_success 1
        exp_continue
    }
    -nocase "bad password"            { exit 22 }
    -nocase "passwords do not match"  { exit 24 }
    -nocase "do not match"            { exit 24 }
    -nocase "error"                   { exit 24 }

    -re $prompt_host_re {
        send "exit\r"
        exit 0
    }
    -re $prompt_dollar_re {
        send "exit\r"
        exit 0
    }

    eof {
        if {$saw_success} {
            exit 0
        } else {
            exit 17
        }
    }

    timeout {
        if {$saw_success} {
            exit 0
        } else {
            exit 21
        }
    }
}
TCLEOF

    expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
    local RC=$?
    rm -f "$TCL_SCRIPT"
    return $RC
}

# ================================
# CORE PROCESS FUNCTION
# ================================
process_node() {
    local LINE="$1"
    local NODE_IP=$(echo "$LINE"   | cut -d'|' -f1)
    local NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME=$(echo "$LINE"  | cut -d'|' -f3)
    local OLD_PASS=$(echo "$LINE"  | cut -d'|' -f4)
    local NEW_PASS=$(echo "$LINE"  | cut -d'|' -f5)

    [[ -z "$USERNAME" ]] && USERNAME="$DEFAULT_USER"

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}_${USERNAME}.log"

    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    {
        echo "=================================================="
        echo " ERICSSON BC PASSWORD RESET LOG"
        echo "=================================================="
        echo " Node IP   : $NODE_IP"
        echo " Node Type : $NODE_TYPE"
        echo " Username  : $USERNAME"
        echo " SSH Port  : $SSH_PORT"
        echo " Command   : $CHANGE_CMD"
        echo " Time      : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        run_bc_reset "$NODE_IP" "$USERNAME" "$OLD_PASS" "$NEW_PASS" "$NODE_LOG"
        RESULT_CODE=$?

        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RESULT_CODE] ---" >> "$NODE_LOG"

        case "$RESULT_CODE" in
            0)  STATUS="SUCCESS"; REASON="Password Updated Successfully" ;;
            10) STATUS="FAILED";  REASON="SSH Timeout" ;;
            11) STATUS="FAILED";  REASON="Connection Refused" ;;
            12) STATUS="FAILED";  REASON="No Route to Host" ;;
            13) STATUS="FAILED";  REASON="Wrong Old Password / Auth Failed" ;;
            17) STATUS="FAILED";  REASON="Connection Closed Unexpectedly (EOF)" ;;
            20) STATUS="FAILED";  REASON="Login Shell Prompt Not Reached" ;;
            21) STATUS="FAILED";  REASON="Password Change Prompt Timeout" ;;
            22) STATUS="FAILED";  REASON="BAD PASSWORD / Policy Violation" ;;
            24) STATUS="FAILED";  REASON="Password Mismatch / Generic Failure" ;;
            *)  STATUS="FAILED";  REASON="Unexpected Error (Code: $RESULT_CODE)" ;;
        esac

        echo "Final Status: $STATUS ($REASON)" >> "$NODE_LOG"

        [[ "$STATUS" == "SUCCESS" ]] && break
        [[ "$RESULT_CODE" == "13" || "$RESULT_CODE" == "22" || "$RESULT_CODE" == "24" ]] && break

        ((ATTEMPT++))
        [[ $ATTEMPT -le $MAX_RETRY ]] && echo "Retrying in 5s..." >> "$NODE_LOG" && sleep 5
    done

    (
        flock -w 10 200
        echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" >> "$OUTPUT_CSV"
    ) 200>"$CSV_LOCK"

    printf "[%s] Node: %-16s | User: %-18s | Status: %-8s | %s\n" \
        "$(date '+%T')" "$NODE_IP" "$USERNAME" "$STATUS" "$REASON"
}

# ================================
# WORKER LOOP
# ================================
export -f process_node run_bc_reset
export LOG_DIR OUTPUT_CSV CSV_LOCK TIMEOUT MAX_RETRY DEFAULT_USER SSH_PORT CHANGE_CMD

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
echo ">>> Full Logs in             : $LOG_DIR"
exit 0

