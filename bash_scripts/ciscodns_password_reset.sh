#!/usr/bin/env bash
# ==============================================================
# ciscodns_password_reset.sh  —  PAMS Password Reset for Cisco DNS nodes
# ==============================================================
# Called by Django as:
#   bash pw_reset_wrapper.sh ciscodns_password_reset.sh <input.csv> <output.csv>
#
# Input CSV columns:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#
# IMPORTANT:
#   - OldPassword = current active password
#   - OldPassword is ALSO the final/original password to restore back to
#   - NewPassword may be blank; if blank, target final password = OldPassword
#
# Output:
#   - Standard output CSV for PAMS
#   - Per-node detailed log
#   - Per-node active password file
#   - Per-node rotation history file
#
# Status:
#   SUCCESS = final/original password restored
#   PARTIAL = password changed, but final/original password could not be restored
#   FAILED  = no useful completion / auth / session failure
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh flock

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=60
MIN_ROTATIONS_BEFORE_RESTORE=6

ROTATION_PASSWORDS=(
  'Am8$ber21'
  'Cr7#own56'
  'Lo5@tus84'
  'Ma6%ngo47'
  'Or9&bit13'
  'Pe4!ble62'
  'Si3$ver48'
  'Ro2#ket35'
)

echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"
CSV_LOCK="${OUTPUT_CSV}.lock"

# ── Parse input CSV ───────────────────────────────────────────
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | \
while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP="$(echo "$IP" | xargs)"
    TYPE="$(echo "$TYPE" | xargs)"
    USER="$(echo "$USER" | xargs)"
    [[ -z "$IP" ]] && continue
    printf '%s|%s|%s|%s|%s\n' "$IP" "$TYPE" "$USER" "$OLD_PASS" "$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting Cisco DNS Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
echo ">>> Detailed node logs: $LOG_DIR"
echo "====================================================================="

# ==============================================================
# SINGLE PASSWORD CHANGE ATTEMPT
# ==============================================================

run_change_once() {
    local NODE_IP="$1"
    local USERNAME="$2"
    local CURRENT_PASS="$3"
    local NEXT_PASS="$4"
    local NODE_LOG="$5"
    local LABEL="$6"

    echo "--- [$LABEL] ---" >> "$NODE_LOG"

    local TCL_SCRIPT
    TCL_SCRIPT=$(mktemp /tmp/ciscodns_XXXXXX.tcl)

    cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_user       {${USERNAME}}
set t_node_ip    {${NODE_IP}}
set t_current    {${CURRENT_PASS}}
set t_next       {${NEXT_PASS}}
set t_timeout    ${TIMEOUT}
VAR_BLOCK

    cat >> "$TCL_SCRIPT" <<'TCLEOF'
set timeout $t_timeout
log_user 1

spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_user@$t_node_ip

set pw_sent 0
set passwd_started 0
set current_sent 0
set new_sent 0
set retype_sent 0
set saw_success 0

expect {
    -nocase "yes/no" { send "yes\r"; exp_continue }
    -nocase "fingerprint" { send "yes\r"; exp_continue }

    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -nocase "access denied"         { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }

    # Expired-login informational lines
    -nocase "you are required to change your password immediately" { exp_continue }
    -nocase "warning: your password has expired"                   { exp_continue }
    -nocase "you must change your password now"                    { exp_continue }
    -nocase "changing password for user"                           { exp_continue }
    -nocase "changing password for"                                { exp_continue }

    # Current password prompt
    -nocase "(current) unix password:" {
        set current_sent 1
        send "$t_current\r"
        exp_continue
    }
    -nocase "current password:" {
        set current_sent 1
        send "$t_current\r"
        exp_continue
    }
    -nocase "old password:" {
        set current_sent 1
        send "$t_current\r"
        exp_continue
    }

    # New password prompt
    -nocase "new password:" {
        set new_sent 1
        send "$t_next\r"
        exp_continue
    }

    # Retype / confirm prompt
    -nocase "retype new password:" {
        set retype_sent 1
        send "$t_next\r"
        exp_continue
    }
    -nocase "re-enter new password:" {
        set retype_sent 1
        send "$t_next\r"
        exp_continue
    }
    -nocase "confirm new password:" {
        set retype_sent 1
        send "$t_next\r"
        exp_continue
    }

    # Success lines
    -nocase "all authentication tokens updated successfully" {
        set saw_success 1
        exp_continue
    }
    -nocase "password updated successfully" {
        set saw_success 1
        exp_continue
    }
    -nocase "password changed." {
        set saw_success 1
        exp_continue
    }

    # Failure / policy lines
    -nocase "password has been already used"           { exit 25 }
    -nocase "have exhausted maximum number of retries" { exit 25 }
    -nocase "do not match"                             { exit 24 }
    -nocase "passwords do not match"                   { exit 24 }
    -nocase "error"                                    { exit 24 }

    # Policy warnings which may still allow retry on same passwd flow
    -nocase "bad password"               { exp_continue }
    -nocase "too simplistic/systematic" { exp_continue }
    -nocase "dictionary check"          { exp_continue }

    # Clean shell prompt
    -re {\[[^]\r\n]+@[^]\r\n]+\][^\r\n]*\$\s*$} {
        if {$passwd_started == 0} {
            set passwd_started 1
            send "passwd\r"
            exp_continue
        } elseif {$saw_success || ($current_sent && $new_sent && $retype_sent)} {
            send "exit\r"
            exit 0
        } else {
            exp_continue
        }
    }

    # Generic $ prompt fallback
    -re {\$\s*$} {
        if {$passwd_started == 0} {
            set passwd_started 1
            send "passwd\r"
            exp_continue
        } elseif {$saw_success || ($current_sent && $new_sent && $retype_sent)} {
            send "exit\r"
            exit 0
        } else {
            exp_continue
        }
    }

    # Initial SSH login password prompt
    -nocase "password:" {
        if {$pw_sent == 0 && $passwd_started == 0 && $current_sent == 0} {
            set pw_sent 1
            send "$t_current\r"
            exp_continue
        } else {
            exit 13
        }
    }

    eof {
        if {$saw_success || ($current_sent && $new_sent && $retype_sent)} {
            exit 0
        } else {
            exit 17
        }
    }

    timeout {
        if {$saw_success || ($current_sent && $new_sent && $retype_sent)} {
            exit 0
        } elseif {$passwd_started || $current_sent || $new_sent || $retype_sent} {
            exit 21
        } else {
            exit 20
        }
    }
}
TCLEOF

    expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
    local RC=$?
    rm -f "$TCL_SCRIPT"

    echo "--- [$LABEL Result: rc=$RC] ---" >> "$NODE_LOG"
    echo "" >> "$NODE_LOG"
    return $RC
}

# ==============================================================
# CORE PROCESS FUNCTION
# ==============================================================

process_node() {
    local LINE="$1"
    local NODE_IP;   NODE_IP=$(echo "$LINE"   | cut -d'|' -f1)
    local NODE_TYPE; NODE_TYPE=$(echo "$LINE" | cut -d'|' -f2)
    local USERNAME;  USERNAME=$(echo "$LINE"  | cut -d'|' -f3)
    local OLD_PASS;  OLD_PASS=$(echo "$LINE"  | cut -d'|' -f4)
    local NEW_PASS;  NEW_PASS=$(echo "$LINE"  | cut -d'|' -f5)

    local TARGET_PASS="$NEW_PASS"
    [[ -z "$TARGET_PASS" ]] && TARGET_PASS="$OLD_PASS"

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}_${USERNAME}.log"
    local ACTIVE_PW_FILE="$LOG_DIR/${SAFE_IP}_${USERNAME}_active_password.txt"
    local HISTORY_FILE="$LOG_DIR/${SAFE_IP}_${USERNAME}_rotation_history.txt"

    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"
    local CURRENT_PASS="$OLD_PASS"
    local ROTATION_COUNT=0
    local RESTORE_DONE=0
    local LAST_RC=0

    write_active_file() {
        local FILE_STATUS="$1"
        {
            echo "Node IP               : $NODE_IP"
            echo "Node Type             : $NODE_TYPE"
            echo "Username              : $USERNAME"
            echo "Requested Final Pass  : $TARGET_PASS"
            echo "Current Active Pass   : $CURRENT_PASS"
            echo "Successful Rotations  : $ROTATION_COUNT"
            echo "State                 : $FILE_STATUS"
            echo "Updated At            : $(date '+%F %T')"
            echo "History File          : $HISTORY_FILE"
        } > "$ACTIVE_PW_FILE"
    }

    append_history() {
        local STEP_LABEL="$1"
        local SET_PASS="$2"
        {
            echo "[$(date '+%F %T')] $STEP_LABEL -> $SET_PASS"
        } >> "$HISTORY_FILE"
    }

    {
        echo "=================================================="
        echo " CISCO DNS PASSWORD RESET LOG"
        echo "=================================================="
        echo " Node IP            : $NODE_IP"
        echo " Node Type          : $NODE_TYPE"
        echo " Username           : $USERNAME"
        echo " Final Target Pw    : OldPassword (or NewPassword if provided)"
        echo " Active Pw File     : $ACTIVE_PW_FILE"
        echo " Rotation History   : $HISTORY_FILE"
        echo " Time               : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    {
        echo "Rotation history for $NODE_IP / $USERNAME"
        echo "Requested final/original password: $TARGET_PASS"
        echo "--------------------------------------------------"
    } > "$HISTORY_FILE"

    write_active_file "INITIAL"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        local IDX=0
        for CANDIDATE in "${ROTATION_PASSWORDS[@]}"; do
            IDX=$((IDX + 1))

            [[ "$CANDIDATE" == "$CURRENT_PASS" ]] && continue
            [[ "$CANDIDATE" == "$TARGET_PASS" ]] && continue

            run_change_once "$NODE_IP" "$USERNAME" "$CURRENT_PASS" "$CANDIDATE" "$NODE_LOG" \
                "ROTATION $IDX : changing to intermediate password"
            LAST_RC=$?

            case "$LAST_RC" in
                0)
                    CURRENT_PASS="$CANDIDATE"
                    ROTATION_COUNT=$((ROTATION_COUNT + 1))
                    echo "[INFO] Rotation $ROTATION_COUNT successful" >> "$NODE_LOG"
                    append_history "ROTATION $ROTATION_COUNT SUCCESS" "$CURRENT_PASS"
                    write_active_file "ROTATION_SUCCESS"

                    if [[ $ROTATION_COUNT -ge $MIN_ROTATIONS_BEFORE_RESTORE ]]; then
                        run_change_once "$NODE_IP" "$USERNAME" "$CURRENT_PASS" "$TARGET_PASS" "$NODE_LOG" \
                            "RESTORE FINAL after $ROTATION_COUNT successful rotations"
                        LAST_RC=$?

                        case "$LAST_RC" in
                            0)
                                CURRENT_PASS="$TARGET_PASS"
                                RESTORE_DONE=1
                                STATUS="SUCCESS"
                                REASON="Final/original password restored successfully after $ROTATION_COUNT rotations"
                                echo "[INFO] $REASON" >> "$NODE_LOG"
                                append_history "FINAL RESTORE SUCCESS" "$CURRENT_PASS"
                                write_active_file "FINAL_RESTORED"
                                break
                                ;;
                            22)
                                echo "[WARN] Final password rejected by policy; continuing more rotations..." >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_POLICY_WARNING"
                                ;;
                            24)
                                echo "[WARN] Final password restore failed (mismatch/generic); continuing more rotations..." >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_GENERIC_FAILURE"
                                ;;
                            25)
                                echo "[WARN] Final password blocked by history; continuing more rotations..." >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_HISTORY_BLOCKED"
                                ;;
                            13)
                                STATUS="FAILED"
                                REASON="Auth failed while trying to restore final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_AUTH_FAILED"
                                break 2
                                ;;
                            10)
                                STATUS="FAILED"; REASON="SSH Timeout while restoring final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_TIMEOUT"
                                break 2
                                ;;
                            11)
                                STATUS="FAILED"; REASON="Connection Refused while restoring final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_CONN_REFUSED"
                                break 2
                                ;;
                            12)
                                STATUS="FAILED"; REASON="No Route to Host while restoring final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_NO_ROUTE"
                                break 2
                                ;;
                            17)
                                STATUS="FAILED"; REASON="Connection Closed unexpectedly while restoring final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_EOF"
                                break 2
                                ;;
                            20)
                                STATUS="FAILED"; REASON="Login shell / forced-change prompt not reached while restoring final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_PROMPT_NOT_REACHED"
                                break 2
                                ;;
                            21)
                                STATUS="FAILED"; REASON="Passwd prompt timeout while restoring final/original password"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_PASSWD_TIMEOUT"
                                break 2
                                ;;
                            *)
                                STATUS="FAILED"
                                REASON="Unexpected failure while restoring final/original password (rc=$LAST_RC)"
                                echo "[ERROR] $REASON" >> "$NODE_LOG"
                                write_active_file "FINAL_RESTORE_UNEXPECTED_FAILURE"
                                break 2
                                ;;
                        esac
                    fi
                    ;;
                22)
                    echo "[WARN] Intermediate password policy warning/rejection; trying next candidate..." >> "$NODE_LOG"
                    write_active_file "INTERMEDIATE_POLICY_WARNING"
                    ;;
                25)
                    echo "[WARN] Intermediate password blocked by history; trying next candidate..." >> "$NODE_LOG"
                    write_active_file "INTERMEDIATE_HISTORY_BLOCKED"
                    ;;
                13)
                    STATUS="FAILED"
                    REASON="Wrong current password / auth failed during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_AUTH_FAILED"
                    break 2
                    ;;
                10)
                    STATUS="FAILED"; REASON="SSH Timeout during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_TIMEOUT"
                    break 2
                    ;;
                11)
                    STATUS="FAILED"; REASON="Connection Refused during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_CONN_REFUSED"
                    break 2
                    ;;
                12)
                    STATUS="FAILED"; REASON="No Route to Host during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_NO_ROUTE"
                    break 2
                    ;;
                17)
                    STATUS="FAILED"; REASON="Connection Closed unexpectedly during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_EOF"
                    break 2
                    ;;
                20)
                    STATUS="FAILED"; REASON="Login shell / forced-change prompt not reached during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_PROMPT_NOT_REACHED"
                    break 2
                    ;;
                21)
                    STATUS="FAILED"; REASON="Passwd prompt timeout during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_PASSWD_TIMEOUT"
                    break 2
                    ;;
                24)
                    STATUS="FAILED"
                    REASON="Password change failed due to mismatch/generic error during rotation"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_GENERIC_FAILURE"
                    break 2
                    ;;
                *)
                    STATUS="FAILED"
                    REASON="Unexpected rotation failure (rc=$LAST_RC)"
                    echo "[ERROR] $REASON" >> "$NODE_LOG"
                    write_active_file "ROTATION_UNEXPECTED_FAILURE"
                    break 2
                    ;;
            esac

            [[ $RESTORE_DONE -eq 1 ]] && break
        done

        if [[ $RESTORE_DONE -eq 1 ]]; then
            break
        fi

        if [[ $ROTATION_COUNT -gt 0 ]]; then
            STATUS="PARTIAL"
            REASON="Final/original password could not be restored after $ROTATION_COUNT rotations; active password saved in file"
            echo "[WARN] $REASON" >> "$NODE_LOG"
            append_history "FINAL STATE PARTIAL" "$CURRENT_PASS"
            write_active_file "PARTIAL_ACTIVE_PASSWORD_LEFT"
        else
            [[ "$STATUS" != "FAILED" ]] && STATUS="FAILED"
            [[ "$REASON" == "Unknown" ]] && REASON="No successful password rotation could be completed"
            echo "[ERROR] $REASON" >> "$NODE_LOG"
            write_active_file "FAILED_NO_ROTATION_SUCCESS"
        fi

        break
    done

    {
        echo ""
        echo "=================================================="
        echo " Final Status      : $STATUS"
        echo " Reason            : $REASON"
        echo " Rotations Success : $ROTATION_COUNT"
        echo " Active Pw File    : $ACTIVE_PW_FILE"
        echo " History File      : $HISTORY_FILE"
        echo "=================================================="
    } >> "$NODE_LOG"

    (
        flock -w 10 200
        echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG ; ActivePwFile=$ACTIVE_PW_FILE ; HistoryFile=$HISTORY_FILE\"" >> "$OUTPUT_CSV"
    ) 200>"$CSV_LOCK"

    printf "[%s] Node: %-18s | User: %-12s | Status: %-8s | %s\n" \
        "$(date '+%T')" "$NODE_IP" "$USERNAME" "$STATUS" "$REASON"
}

# ==============================================================
# WORKER LOOP
# ==============================================================
export -f process_node run_change_once
export LOG_DIR OUTPUT_CSV CSV_LOCK TIMEOUT MAX_RETRY MIN_ROTATIONS_BEFORE_RESTORE

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

