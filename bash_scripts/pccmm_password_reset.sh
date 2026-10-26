#!/bin/bash
# ==============================================================
# mme_password_reset.sh (Django Integrated & Automated)
# ==============================================================
# Called by Django as:
#   bash mme_password_reset.sh <input.csv> <output.csv>
#
# Input CSV Format:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#
# ---------------------------------------------------------------
# MME Node Flow (Wind River Linux / ASGHSGSN-type):
#   1. SSH login                -> send OldPassword
#   2. Wait for shell prompt #  -> send "passwd"
#   3. "Current Password:"      -> send OldPassword
#   4. "Enter new password:"    -> send NewPassword
#   5. "Confirm new password:"  -> send NewPassword
#   6. "password updated successfully" -> exit 0
#
# PCG Node Flow (Packet Core Gateway):
#   PRIMARY PATH (password expired, most nodes):
#     1. SSH login ("Password:")         -> send OldPassword
#     2. "Password expired..."           -> auto (exp_continue)
#     3. "Current Password:"             -> send OldPassword
#     4. "New Password:"                 -> send NewPassword
#     5. "Reenter new Password:"         -> send NewPassword
#     6. "Welcome"                       -> exit 0
#
#   FALLBACK PATH (non-expired account):
#     1. SSH login ("Password:")         -> send OldPassword
#     2. Shell "#" prompt                -> send "change-password"
#        NOTE: PCG uses "change-password" NOT "passwd"
#     3. "Current Password:"             -> send OldPassword
#     4. "New Password:"                 -> send NewPassword
#     5. "Reenter new Password:"         -> send NewPassword
#     6. "Welcome"                       -> exit 0
#
#   AUTH FAILURE DETECTION:
#     If SSH re-prompts with "user@host's password:" after STAGE 1
#     already sent OldPassword, it means OLD PASSWORD WAS REJECTED.
#     -> exit 13 (Wrong Old Password / Permission Denied)
#
# ---------------------------------------------------------------
# PCCSM Node Flow (Packet Core Cloud Service Manager):
#   PRIMARY PATH (non-expired, most nodes):
#     1. SSH login ("Password:")              -> send OldPassword
#     2. "Password will expire in N days"     -> skip (exp_continue)
#     3. "Welcome"                            -> skip (exp_continue)
#     4. "Last login time: ..."               -> skip (exp_continue)
#     5. "connected from ..."                 -> skip (exp_continue)
#     6. Shell "#" prompt                     -> send "change-password"
#        NOTE: PCCSM uses "change-password" NOT "passwd"
#     7. "Enter current password:"            -> send OldPassword
#     8. "Enter a new password:"              -> send NewPassword
#     9. "Confirm password:"                  -> send NewPassword
#    10. "Password updated successfully"      -> exit 0
#
#   DEFENSIVE PATH (password expired — not observed but guarded):
#     1. SSH login ("Password:")              -> send OldPassword
#     2. "Password expired..."               -> auto (exp_continue)
#     3. "Enter current password:"            -> send OldPassword
#     4. "Enter a new password:"              -> send NewPassword
#     5. "Confirm password:"                  -> send NewPassword
#     6. "Password updated successfully"      -> exit 0
#
#   AUTH FAILURE DETECTION:
#     If SSH re-prompts with "user@host's password:" after STAGE 1
#     already sent OldPassword, it means OLD PASSWORD WAS REJECTED.
#     -> exit 13 (Wrong Old Password / Permission Denied)
# ---------------------------------------------------------------
# ROOT CAUSE FIX for "can't read $VAR: no such variable":
#   Passwords are written into a temp Tcl file as Tcl variables
#   inside {curly braces} BEFORE expect runs. Tcl curly braces
#   are fully literal – special chars $ [ \ { } space are safe.
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
pams_init "$@"
pams_check_deps expect ssh

MAX_RETRY=1
MAX_PARALLEL=3
TIMEOUT=45

echo "NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile" > "$OUTPUT_CSV"

# ================================
# PARSE INPUT CSV
# ================================
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP=$(echo "$IP" | xargs)
    [[ -z "$IP" ]] && continue
    echo "$IP|$TYPE|$USER|$OLD_PASS|$NEW_PASS" >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
echo ">>> Logs: $LOG_DIR"
echo "====================================================================="

# ================================
# CORE PASSWORD RESET FUNCTION
# ================================
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

    # Normalize node type for case-insensitive branching
    # e.g. pcg/PCG/Pcg -> PCG   |   pccsm/PCCSM -> PCCSM
    local NODE_TYPE_NORM
    NODE_TYPE_NORM=$(echo "$NODE_TYPE" | tr '[:lower:]' '[:upper:]' | xargs)

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

        # ----------------------------------------------------------
        # THE FIX: Write a temp Tcl/expect script file.
        # Bash expands shell variables into Tcl "set" statements
        # wrapped in {curly braces}. Tcl curly braces = fully
        # literal string – no substitution whatsoever. So passwords
        # containing  $ [ \ " { } space  are 100% safe.
        # ----------------------------------------------------------
        local TCL_SCRIPT
        TCL_SCRIPT=$(mktemp /tmp/expect_XXXXXX.tcl)

        # Part 1: variable declarations – bash expands values here,
        # Tcl stores them literally inside the curly braces.
        cat > "$TCL_SCRIPT" <<VAR_BLOCK
set t_user     {${USERNAME}}
set t_node_ip  {${NODE_IP}}
set t_old_pass {${OLD_PASS}}
set t_new_pass {${NEW_PASS}}
set t_timeout  ${TIMEOUT}
VAR_BLOCK

        # Part 2: node-type-specific expect logic – single-quoted
        # heredoc so bash passes it verbatim; Tcl uses $t_* vars set above.
        case "$NODE_TYPE_NORM" in

            # ============================================================
            # PCG: Packet Core Gateway
            # ============================================================
            PCG)
                cat >> "$TCL_SCRIPT" <<'TCLEOF'

set timeout $t_timeout
log_user 1

# STAGE 1: SSH LOGIN
# Note: "-nocase password:" matches both "Password:" and "user@host's password:"
# since the latter contains "password:" as a substring. Both are handled.
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

# STAGE 2: Post-login gate
#
# If SSH re-prompts with "user@host's password:" here, it means STAGE 1
# already sent OldPassword and it was REJECTED by the server.
# This is a wrong old password condition -> exit 13.
# Do NOT retry the password here – a second prompt = authentication failure.
#
# Normal flows after successful STAGE 1 auth:
#   [A] Expired path  : "Password expired..." -> "Current Password:"
#   [B] Fallback path : Shell "#" prompt -> send "change-password"
expect {
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }

    # --- WRONG OLD PASSWORD: SSH re-prompted after STAGE 1 already sent OldPassword ---
    # A second password prompt means the first was rejected. Mark as wrong password.
    -nocase "'s password:"          { exit 13 }

    # --- PATH A: standard expired flow ---
    -nocase "password expired"      { exp_continue }
    -nocase "current password:"     { send $t_old_pass\r }
    -nocase "old password:"         { send $t_old_pass\r }

    # --- PATH B: non-expired account, reaches shell — run change-password manually ---
    # NOTE: PCG uses "change-password" command, NOT "passwd"
    -re {#\s*$} {
        send "change-password\r"
        expect {
            -nocase "current password:" { send $t_old_pass\r }
            -nocase "old password:"     { send $t_old_pass\r }
            timeout                     { exit 21 }
            eof                         { exit 17 }
        }
    }

    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# STAGE 3: Enter new password
expect {
    -nocase "new password:"         { send $t_new_pass\r }
    -nocase "bad password"          { exit 20 }
    -nocase "authentication token"  { exit 20 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# STAGE 4: Reenter / Confirm new password
# PCG uses "Reenter new Password:" — broader fallbacks also handled.
expect {
    -nocase "reenter new password:" { send $t_new_pass\r }
    -nocase "confirm new password:" { send $t_new_pass\r }
    -nocase "retype new password:"  { send $t_new_pass\r }
    -nocase "re-enter"              { send $t_new_pass\r }
    -nocase "reenter"               { send $t_new_pass\r }
    -nocase "confirm"               { send $t_new_pass\r }
    -nocase "retype"                { send $t_new_pass\r }
    -nocase "bad password"          { exit 20 }
    -nocase "do not match"          { exit 22 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# STAGE 5: Confirm result
# PCG prints "Welcome" immediately after a successful password change.
expect {
    -nocase "bad password"           { exit 20 }
    -nocase "failure"                { exit 20 }
    -nocase "unchanged"              { exit 20 }
    -nocase "do not match"           { exit 22 }
    -nocase "passwords do not match" { exit 22 }
    -nocase "authentication token"   { exit 20 }
    -nocase "permission denied"      { exit 13 }

    # --- PCG PRIMARY SUCCESS INDICATOR ---
    -nocase "welcome"                { exit 0 }

    # --- Generic fallbacks ---
    -nocase "updated successfully"   { exit 0 }
    -nocase "successfully"           { exit 0 }
    -nocase "updated"                { exit 0 }

    # Shell prompt as last-resort (non-expired fallback path)
    -re {#\s*$}                      { send "exit\r"; exit 0 }

    timeout                          { exit 21 }
    eof                              { exit 17 }
}
TCLEOF
                ;;  # end PCG

            # ============================================================
            # PCCSM: Packet Core Cloud Service Manager
            # ============================================================
            # Observed flow (non-expired account — most common):
            #   SSH login -> banner -> "Password:" -> OldPassword
            #   -> "Password will expire in N days" (skip)
            #   -> "Welcome" (skip)
            #   -> "Last login time: ..." (skip)
            #   -> "connected from ..." (skip)
            #   -> shell "#" -> "change-password"
            #   -> "Enter current password:" -> OldPassword
            #   -> "Enter a new password:"   -> NewPassword
            #   -> "Confirm password:"       -> NewPassword
            #   -> "Password updated successfully" -> exit 0
            #
            # Defensive expired path (not observed, guarded for safety):
            #   SSH login -> "Password expired..." -> exp_continue
            #   -> "Enter current password:"       -> OldPassword
            #   -> same new/confirm/success flow
            #
            # NOTE: PCCSM uses "change-password" (same as PCG), NOT "passwd"
            # NOTE: Success is "Password updated successfully" (NOT "Welcome")
            # ============================================================
            PCCMM)
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

# STAGE 2: Post-login gate
#
# PCCSM post-auth output sequence observed in logs:
#   "Password will expire in N days"   (informational – skip)
#   "Welcome"                          (informational – skip)
#   "Last login time: ..."             (informational – skip)
#   "espdtmb connected from ... ssh"   (informational – skip)
#   "user@host#"                       (shell prompt  – act)
#
# If SSH re-prompts with "user@host's password:" here, it means STAGE 1
# already sent OldPassword and it was REJECTED -> exit 13.
#
# Defensive expired path: if node ever sends "Enter current password:"
# before we reach the shell, send OldPassword and proceed normally.
expect {
    -nocase "permission denied"       { exit 13 }
    -nocase "authentication failed"   { exit 13 }
    -nocase "login incorrect"         { exit 13 }

    # WRONG OLD PASSWORD: SSH re-prompted after STAGE 1 already sent OldPassword
    -nocase "'s password:"            { exit 13 }

    # ---- Informational post-auth messages — skip over all of them ----
    -nocase "password will expire"    { exp_continue }
    -nocase "welcome"                 { exp_continue }
    -nocase "last login"              { exp_continue }
    -nocase "connected from"          { exp_continue }

    # ---- DEFENSIVE: expired-password intercept (not seen in logs) ----
    -nocase "password expired"        { exp_continue }
    -nocase "enter current password:" { send $t_old_pass\r }
    -nocase "current password:"       { send $t_old_pass\r }

    # ---- PRIMARY PATH: shell prompt reached — run change-password ----
    # PCCSM uses "change-password", NOT "passwd"
    -re {#\s*$} {
        send "change-password\r"
        expect {
            -nocase "enter current password:" { send $t_old_pass\r }
            -nocase "current password:"       { send $t_old_pass\r }
            -nocase "old password:"           { send $t_old_pass\r }
            timeout                           { exit 21 }
            eof                               { exit 17 }
        }
    }

    timeout                           { exit 10 }
    eof                               { exit 17 }
}

# STAGE 3: Enter new password
# PCCSM prompt: "Enter a new password:"
# "new password:" is a substring match — catches both exact and prefixed variants.
expect {
    -nocase "enter a new password:"   { send $t_new_pass\r }
    -nocase "new password:"           { send $t_new_pass\r }
    -nocase "bad password"            { exit 20 }
    -nocase "authentication token"    { exit 20 }
    timeout                           { exit 21 }
    eof                               { exit 17 }
}

# STAGE 4: Confirm new password
# PCCSM prompt: "Confirm password:"
# More specific patterns listed first; generic fallbacks at the end.
expect {
    -nocase "confirm password:"       { send $t_new_pass\r }
    -nocase "confirm new password:"   { send $t_new_pass\r }
    -nocase "reenter new password:"   { send $t_new_pass\r }
    -nocase "retype new password:"    { send $t_new_pass\r }
    -nocase "re-enter"                { send $t_new_pass\r }
    -nocase "reenter"                 { send $t_new_pass\r }
    -nocase "confirm"                 { send $t_new_pass\r }
    -nocase "retype"                  { send $t_new_pass\r }
    -nocase "bad password"            { exit 20 }
    -nocase "do not match"            { exit 22 }
    timeout                           { exit 21 }
    eof                               { exit 17 }
}

# STAGE 5: Confirm result
# PCCSM PRIMARY SUCCESS: "Password updated successfully"
# After success PCCSM returns to shell prompt — send "exit" to clean up.
expect {
    -nocase "bad password"                    { exit 20 }
    -nocase "failure"                         { exit 20 }
    -nocase "unchanged"                       { exit 20 }
    -nocase "do not match"                    { exit 22 }
    -nocase "passwords do not match"          { exit 22 }
    -nocase "authentication token"            { exit 20 }
    -nocase "permission denied"               { exit 13 }

    # ---- PCCSM PRIMARY SUCCESS INDICATOR ----
    -nocase "password updated successfully"   { send "exit\r"; exit 0 }

    # ---- Generic fallbacks ----
    -nocase "updated successfully"            { send "exit\r"; exit 0 }
    -nocase "successfully"                    { send "exit\r"; exit 0 }
    -nocase "updated"                         { send "exit\r"; exit 0 }

    # Shell prompt as last-resort (lands here after success on some versions)
    -re {#\s*$}                               { send "exit\r"; exit 0 }

    timeout                                   { exit 21 }
    eof                                       { exit 17 }
}
TCLEOF
                ;;  # end PCCSM

            # ============================================================
            # MME (default): Wind River Linux / ASGHSGSN-type
            # ============================================================
            # Must reach shell (#) first, then run "passwd" manually.
            # Success indicator: "password updated successfully"
            # Confirm prompt:    "Confirm new password:"
            # ============================================================
            *)
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

# STAGE 2 & 3a: WAIT FOR MME SHELL PROMPT OR EXPIRED PASSWORD PROMPT
# Merging original wait and first step of passwd dialogue to catch
# expired passwords early before a shell prompt is reached.
expect {
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }

    # --- EXPIRED PASSWORD INTERCEPT ROUTE ---
    -nocase "password expired"      { exp_continue }
    -nocase "current password:"     { send $t_old_pass\r }
    -nocase "old password:"         { send $t_old_pass\r }
    -nocase "current"               { send $t_old_pass\r }

    # --- STANDARD SHELL ROUTE ---
    # MME prompt pattern: "=== <hostname> <user>@<blade> ~ #"
    -re {#\s*$} {
        send "passwd\r"
        expect {
            -nocase "current password:" { send $t_old_pass\r }
            -nocase "current"           { send $t_old_pass\r }
            -nocase "old password:"     { send $t_old_pass\r }
            timeout                     { exit 21 }
            eof                         { exit 17 }
        }
    }

    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# STAGE 3b: Enter new password
expect {
    -nocase "enter new password:"   { send $t_new_pass\r }
    -nocase "new password:"         { send $t_new_pass\r }
    -nocase "bad password"          { exit 20 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# STAGE 3c: Confirm new password
expect {
    -nocase "confirm new password:" { send $t_new_pass\r }
    -nocase "confirm"               { send $t_new_pass\r }
    -nocase "retype"                { send $t_new_pass\r }
    -nocase "re-enter"              { send $t_new_pass\r }
    -nocase "bad password"          { exit 20 }
    -nocase "do not match"          { exit 22 }
    timeout                         { exit 21 }
    eof                             { exit 17 }
}

# STAGE 4: Confirm result
expect {
    -nocase "bad password"          { exit 20 }
    -nocase "failure"               { exit 20 }
    -nocase "unchanged"             { exit 20 }
    -nocase "do not match"          { exit 22 }
    -nocase "authentication token"  { exit 20 }
    -nocase "permission denied"     { exit 13 }

    -nocase "updated successfully"  { send "exit\r"; exit 0 }
    -nocase "successfully"          { send "exit\r"; exit 0 }
    -nocase "updated"               { send "exit\r"; exit 0 }

    # Catch for expired password route which returns to shell on success
    -re {#\s*$}                     { send "exit\r"; exit 0 }

    timeout                         { exit 21 }
    eof                             { exit 17 }
}
TCLEOF
                ;;  # end MME

        esac

        expect "$TCL_SCRIPT" >> "$NODE_LOG" 2>&1
        RESULT_CODE=$?
        rm -f "$TCL_SCRIPT"

        echo "" >> "$NODE_LOG"
        echo "--- [Expect Exit Code: $RESULT_CODE] ---" >> "$NODE_LOG"

        case "$RESULT_CODE" in
            0)  STATUS="SUCCESS"; REASON="OS Password Updated Successfully";;
            10) STATUS="FAILED";  REASON="SSH Timeout / Host Unreachable";;
            11) STATUS="FAILED";  REASON="Connection Refused";;
            12) STATUS="FAILED";  REASON="No Route to Host";;
            13) STATUS="FAILED";  REASON="Wrong Old Password / Permission Denied";;
            17) STATUS="FAILED";  REASON="Connection Closed Unexpectedly (EOF)";;
            20) STATUS="FAILED";  REASON="Password Rejected (bad/weak/same/policy)";;
            21) STATUS="FAILED";  REASON="passwd Prompt Timeout";;
            22) STATUS="FAILED";  REASON="Passwords Did Not Match";;
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
echo ">>> Done! Results written to : $OUTPUT_CSV"
echo ">>> Full Execution Logs in   : $LOG_DIR"
exit 0

