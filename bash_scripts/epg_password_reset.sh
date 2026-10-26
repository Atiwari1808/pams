#!/usr/bin/env bash
# ipos_password_reset.sh  —  PAMS Password Reset for Ericsson IPOS Nodes
# ==============================================================
# Node Type : IPOS (Ericsson IPOS — PCGW, WMG, etc.)
# Called by : bash pw_reset_wrapper.sh ipos_password_reset.sh <input.csv> <output.csv>
#
# Input CSV columns:
#   NodeIP, NodeType, Username, OldPassword, NewPassword
#
#   IMPORTANT:
#     OldPassword = ebdmots user's current password (the IPOS privileged admin)
#                   NOT the target user's password.
#     Username    = the user whose password is to be reset (e.g. ebdmots, espdtmb)
#     NewPassword = the final password to set for the target user
#
# Password Reset Flow:
#
#   PHASE 1 — Set a TEMP password for USERNAME via ebdmots IPOS CLI:
#     SSH as ebdmots using OldPassword
#     → [local]HOSTNAME#  →  config
#     → system authentication user <USERNAME> password <TEMP>
#     → validate  →  commit  →  exit  →  exit  →  exit
#
#   PHASE 2 — Login as USERNAME with TEMP password:
#
#     PATH A (most nodes — forced expiry):
#       "WARNING: Your password has expired."
#       → Current password: TEMP
#       → New password:     NEW
#       → Retype:           NEW
#       → "password updated successfully"  →  SUCCESS
#
#     PATH B (some nodes — no forced expiry, shell reached):
#       [local]HOSTNAME# reached  →  exit session
#       → PHASE 1b: re-login as ebdmots, set USERNAME password = NEW directly
#         (if USERNAME == ebdmots: use TEMP as ebdmots login cred)
#         (if USERNAME != ebdmots: use original EBDMOTS_OLD_PASS)
#         → validate  →  commit  →  exit  →  exit  →  exit  →  SUCCESS
#
# Exit Codes:
#   0  = SUCCESS
#   10 = SSH Timeout
#   11 = Connection Refused
#   12 = No Route to Host
#   13 = Wrong Password / Auth Failed
#   17 = EOF / Connection Closed
#   20 = Password Rejected (policy)
#   22 = Passwords Did Not Match
#   40 = PATH B signal (shell reached, no expiry — internal use)
#   51 = IPOS CLI Prompt Timeout
#   52 = IPOS Validation Failed
#   53 = IPOS Commit Failed
#   61 = Password-Change Prompt Timeout (Phase 2 PATH A)
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

# ── Temp-password generator ───────────────────────────────────
# Produces a 12-char temp password that satisfies typical IPOS
# password policy: uppercase + lowercase + digit + special char.
# Format: Tx<8 random alphanum>!1
generate_temp_pass() {
    local -a prefixes=("Pams" "Eric" "Temp" "Node" "Netops" "Pass")
    local word="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
    local num
    num=$(( RANDOM % 9000 + 1000 ))   # always 4 digits: 1000–9999
    printf '%s$%04d' "$word" "$num"
}

# ── Parse input CSV into pipe-delimited temp file ─────────────
PARSED_FILE=$(mktemp)
DELIM=","
head -n 1 "$INPUT_CSV" | grep -qP '\t' && DELIM=$'\t'

tail -n +2 "$INPUT_CSV" | tr -d '\r' | \
while IFS="$DELIM" read -r IP TYPE USER OLD_PASS NEW_PASS _REST; do
    IP=$(echo "$IP" | xargs)
    [[ -z "$IP" ]] && continue
    printf '%s|%s|%s|%s|%s\n' "$IP" "$TYPE" "$USER" "$OLD_PASS" "$NEW_PASS" \
        >> "$PARSED_FILE"
done

TOTAL_NODES=$(wc -l < "$PARSED_FILE")
echo ">>> Starting IPOS Password Reset for $TOTAL_NODES node(s) (Parallel: $MAX_PARALLEL)"
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
    local EBDMOTS_PASS; EBDMOTS_PASS=$(echo "$LINE" | cut -d'|' -f4)  # OldPassword = ebdmots cred
    local NEW_PASS;  NEW_PASS=$(echo "$LINE"  | cut -d'|' -f5)

    local SAFE_IP="${NODE_IP//:/_}"
    local NODE_LOG="$LOG_DIR/${SAFE_IP}_${USERNAME}.log"
    local ATTEMPT=1
    local STATUS="FAILED"
    local REASON="Unknown"

    # Generate a unique temp password for this node's reset run
    local TEMP_PASS
    TEMP_PASS=$(generate_temp_pass)

    # Determine Phase 1b login password for ebdmots:
    #   - If resetting ebdmots itself  → its password is now TEMP after Phase 1
    #   - If resetting another user    → ebdmots password unchanged; use original
    local PHASE1B_EBDMOTS_PASS
    if [[ "${USERNAME,,}" == "ebdmots" ]]; then
        PHASE1B_EBDMOTS_PASS="$TEMP_PASS"
    else
        PHASE1B_EBDMOTS_PASS="$EBDMOTS_PASS"
    fi

    {
        echo "=================================================="
        echo " IPOS SSH PASSWORD RESET LOG"
        echo "=================================================="
        echo " Node IP      : $NODE_IP"
        echo " Node Type    : $NODE_TYPE"
        echo " Target User  : $USERNAME"
        echo " Admin User   : ebdmots"
        echo " Temp Pass    : $TEMP_PASS"
        echo " Time         : $(date '+%F %T')"
        echo "=================================================="
        echo ""
    } > "$NODE_LOG"

    while [ $ATTEMPT -le $MAX_RETRY ]; do
        echo "--- [Attempt $ATTEMPT of $MAX_RETRY] ---" >> "$NODE_LOG"

        # ──────────────────────────────────────────────────────
        # PHASE 1: Login as ebdmots, set TEMP password for USERNAME
        # ──────────────────────────────────────────────────────
        echo "--- [PHASE 1: Setting TEMP password for '${USERNAME}' via ebdmots CLI] ---" \
            >> "$NODE_LOG"

        local TCL_P1
        TCL_P1=$(mktemp /tmp/ipos_p1_XXXXXX.tcl)

        # Part 1: bash injects values as Tcl literals in {curly braces}
        # Curly braces = fully literal in Tcl → safe for $, [, \, ", { }, space
        cat > "$TCL_P1" <<VAR_BLOCK
set t_node_ip   {${NODE_IP}}
set t_ebdmots   {ebdmots}
set t_ebdpass   {${EBDMOTS_PASS}}
set t_username  {${USERNAME}}
set t_temp_pass {${TEMP_PASS}}
set t_timeout   ${TIMEOUT}
VAR_BLOCK

        # Part 2: static Tcl/expect logic — bash never touches this block
        cat >> "$TCL_P1" <<'TCLEOF'
set timeout $t_timeout
log_user 1

# ── STAGE 1: SSH as ebdmots ───────────────────────────────────
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_ebdmots@$t_node_ip

expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "password:"             { send $t_ebdpass\r }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── STAGE 2: Wait for IPOS shell prompt [local]HOSTNAME# ─────
# Absorbs: Notice banner, "WARNING: password will expire", Last login, Welcome text
expect {
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "login incorrect"       { exit 13 }
    -re {\[local\].*#\s*$}          { send "config\r" }
    -re {#\s*$}                     { send "config\r" }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── STAGE 3: Config mode — wait for (config)# prompt ─────────
expect {
    -nocase "entering configuration" { exp_continue }
    -re {\(config\)#\s*$}           {
        send "system authentication user $t_username password $t_temp_pass\r"
    }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── STAGE 4: Wait for (config-user-USERNAME)# prompt ─────────
expect {
    -re {\(config-user.*\)#\s*$}    { send "validate\r" }
    -nocase "error"                 { exit 52 }
    -nocase "invalid"               { exit 52 }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── STAGE 5: Validation ───────────────────────────────────────
expect {
    -nocase "validation complete"   { }
    -nocase "error"                 { exit 52 }
    -nocase "failed"                { exit 52 }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# Wait for prompt to return after "Validation complete"
expect {
    -re {\(config-user.*\)#\s*$}    { send "commit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── STAGE 6: Commit ───────────────────────────────────────────
expect {
    -nocase "commit complete"       { }
    -nocase "error"                 { exit 53 }
    -nocase "failed"                { exit 53 }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# Wait for prompt after "Commit complete."
expect {
    -re {\(config-user.*\)#\s*$}    { send "exit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── STAGE 7: exit config-user → (config)# ────────────────────
expect {
    -re {\(config\)#\s*$}           { send "exit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── STAGE 8: exit config → [local]HOSTNAME# ──────────────────
expect {
    -re {\[local\].*#\s*$}          { send "exit\r" }
    -re {#\s*$}                     { send "exit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── STAGE 9: Connection close ─────────────────────────────────
expect eof
exit 0
TCLEOF

        expect "$TCL_P1" >> "$NODE_LOG" 2>&1
        local P1_RC=$?
        rm -f "$TCL_P1"

        echo "" >> "$NODE_LOG"
        echo "--- [Phase 1 Exit Code: $P1_RC] ---" >> "$NODE_LOG"

        if [[ $P1_RC -ne 0 ]]; then
            case "$P1_RC" in
            10) REASON="SSH Timeout — Phase 1 (ebdmots login)";;
            11) REASON="Connection Refused — Phase 1";;
            12) REASON="No Route to Host — Phase 1";;
            13) REASON="Wrong ebdmots Password / Permission Denied — Phase 1";;
            17) REASON="Connection Closed Unexpectedly — Phase 1";;
            51) REASON="IPOS CLI Prompt Timeout — Phase 1";;
            52) REASON="IPOS Validation Failed — Phase 1";;
            53) REASON="IPOS Commit Failed — Phase 1";;
             *) REASON="Phase 1 Unexpected Error (exit code: $P1_RC)";;
            esac
            echo "Final Status: FAILED ($REASON)" >> "$NODE_LOG"
            break
        fi

        echo "--- [PHASE 1 COMPLETE: Temp password set for '${USERNAME}'] ---" \
            >> "$NODE_LOG"

        # Small sleep to allow IPOS to propagate the new credential
        sleep 2

        # ──────────────────────────────────────────────────────
        # PHASE 2: Login as USERNAME with TEMP password
        #   PATH A → password-expired prompt  → change it now
        #   PATH B → shell reached            → exit 40 (fallback needed)
        # ──────────────────────────────────────────────────────
        echo "--- [PHASE 2: Login as '${USERNAME}' with temp password] ---" \
            >> "$NODE_LOG"

        local TCL_P2
        TCL_P2=$(mktemp /tmp/ipos_p2_XXXXXX.tcl)

        cat > "$TCL_P2" <<VAR_BLOCK
set t_node_ip   {${NODE_IP}}
set t_username  {${USERNAME}}
set t_temp_pass {${TEMP_PASS}}
set t_new_pass  {${NEW_PASS}}
set t_timeout   ${TIMEOUT}
VAR_BLOCK

        cat >> "$TCL_P2" <<'TCLEOF'
set timeout $t_timeout
log_user 1

# ── STAGE 1: SSH as USERNAME with TEMP password ───────────────
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_username@$t_node_ip

expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "password:"             { send $t_temp_pass\r }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── STAGE 2: Post-login gate — PATH A or PATH B ──────────────
#
# PATH A: Server forces password change immediately after login.
#   Sequence from logs:
#     "WARNING: Your password has expired."
#     "You must change your password now and login again!"
#     "Current password:"  ← we send TEMP
#
# PATH B: Shell reached without forced change.
#   [local]HOSTNAME# appears  → exit 40 to signal bash fallback.
#
# Absorbs: Notice banner, "WARNING: will expire in N days"
expect {
    -nocase "permission denied"         { exit 13 }
    -nocase "authentication failed"     { exit 13 }
    -nocase "login incorrect"           { exit 13 }
    # PATH A indicators — absorb and keep waiting for "Current password:"
    -nocase "password has expired"      { exp_continue }
    -nocase "password expired"          { exp_continue }
    -nocase "must change your password" { exp_continue }
    -nocase "login again"               { exp_continue }
    # PATH A: "Current password:" → send TEMP, then fall through to sequential expects
    -nocase "current password:"         { send $t_temp_pass\r }
    # PATH B: Shell prompt reached, no forced change
    -re {\[local\].*#\s*$}              { send "exit\r"; exit 40 }
    -re {#\s*$}                         { send "exit\r"; exit 40 }
    timeout                             { exit 10 }
    eof                                 { exit 17 }
}

# ── STAGE 3 (PATH A only): Enter new password ────────────────
expect {
    -nocase "new password:"             { send $t_new_pass\r }
    -nocase "bad password"              { exit 20 }
    -nocase "authentication token"      { exit 20 }
    timeout                             { exit 61 }
    eof                                 { exit 17 }
}

# ── STAGE 4 (PATH A only): Retype / Confirm new password ─────
expect {
    -nocase "retype new password:"      { send $t_new_pass\r }
    -nocase "re-enter new password:"    { send $t_new_pass\r }
    -nocase "confirm new password:"     { send $t_new_pass\r }
    -nocase "re-enter"                  { send $t_new_pass\r }
    -nocase "confirm"                   { send $t_new_pass\r }
    -nocase "retype"                    { send $t_new_pass\r }
    -nocase "bad password"              { exit 20 }
    -nocase "do not match"              { exit 22 }
    timeout                             { exit 61 }
    eof                                 { exit 17 }
}

# ── STAGE 5 (PATH A only): Confirm result ────────────────────
expect {
    -nocase "password updated successfully" { exit 0 }
    -nocase "updated successfully"          { exit 0 }
    -nocase "successfully"                  { exit 0 }
    -nocase "bad password"                  { exit 20 }
    -nocase "do not match"                  { exit 22 }
    -nocase "failure"                       { exit 20 }
    -nocase "unchanged"                     { exit 20 }
    # Connection may close immediately after success on some nodes
    timeout                                 { exit 61 }
    eof                                     { exit 0 }
}
TCLEOF

        expect "$TCL_P2" >> "$NODE_LOG" 2>&1
        local P2_RC=$?
        rm -f "$TCL_P2"

        echo "" >> "$NODE_LOG"
        echo "--- [Phase 2 Exit Code: $P2_RC] ---" >> "$NODE_LOG"

        if [[ $P2_RC -eq 0 ]]; then
            # ── PATH A SUCCESS ────────────────────────────────
            STATUS="SUCCESS"
            REASON="Password Changed via Expiry Prompt (PATH A)"
            echo "Final Status: SUCCESS (PATH A - password expiry route)" >> "$NODE_LOG"
            break

        elif [[ $P2_RC -eq 40 ]]; then
            # ── PATH B: Shell reached — run PHASE 1b ─────────
            echo "--- [PATH B: Shell prompt detected, no forced expiry]" \
                >> "$NODE_LOG"
            echo "--- [PHASE 1b: Setting NEW password directly for '${USERNAME}' via ebdmots] ---" \
                >> "$NODE_LOG"

            local TCL_P1B
            TCL_P1B=$(mktemp /tmp/ipos_p1b_XXXXXX.tcl)

            cat > "$TCL_P1B" <<VAR_BLOCK
set t_node_ip    {${NODE_IP}}
set t_ebdmots    {ebdmots}
set t_p1b_pass   {${PHASE1B_EBDMOTS_PASS}}
set t_username   {${USERNAME}}
set t_new_pass   {${NEW_PASS}}
set t_timeout    ${TIMEOUT}
VAR_BLOCK

            cat >> "$TCL_P1B" <<'TCLEOF'
set timeout $t_timeout
log_user 1

# ── PHASE 1b STAGE 1: SSH as ebdmots ─────────────────────────
# If resetting ebdmots itself: t_p1b_pass = TEMP (password was changed in Phase 1)
# If resetting another user:   t_p1b_pass = original ebdmots password
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o NumberOfPasswordPrompts=1 \
    $t_ebdmots@$t_node_ip

expect {
    -nocase "yes/no"                { send "yes\r"; exp_continue }
    -nocase "fingerprint"           { send "yes\r"; exp_continue }
    -nocase "password:"             { send $t_p1b_pass\r }
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -nocase "connection refused"    { exit 11 }
    -nocase "no route to host"      { exit 12 }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 2: Wait for IPOS shell ────────────────────
expect {
    -nocase "permission denied"     { exit 13 }
    -nocase "authentication failed" { exit 13 }
    -re {\[local\].*#\s*$}          { send "config\r" }
    -re {#\s*$}                     { send "config\r" }
    timeout                         { exit 10 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 3: Config mode ────────────────────────────
expect {
    -nocase "entering configuration" { exp_continue }
    -re {\(config\)#\s*$}           {
        send "system authentication user $t_username password $t_new_pass\r"
    }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 4: (config-user-USERNAME)# ────────────────
expect {
    -re {\(config-user.*\)#\s*$}    { send "validate\r" }
    -nocase "error"                 { exit 52 }
    -nocase "invalid"               { exit 52 }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 5: Validation ─────────────────────────────
expect {
    -nocase "validation complete"   { }
    -nocase "error"                 { exit 52 }
    -nocase "failed"                { exit 52 }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

expect {
    -re {\(config-user.*\)#\s*$}    { send "commit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 6: Commit ─────────────────────────────────
expect {
    -nocase "commit complete"       { }
    -nocase "error"                 { exit 53 }
    -nocase "failed"                { exit 53 }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

expect {
    -re {\(config-user.*\)#\s*$}    { send "exit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 7: exit → (config)# ──────────────────────
expect {
    -re {\(config\)#\s*$}           { send "exit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

# ── PHASE 1b STAGE 8: exit → [local]HOSTNAME# ────────────────
expect {
    -re {\[local\].*#\s*$}          { send "exit\r" }
    -re {#\s*$}                     { send "exit\r" }
    timeout                         { exit 51 }
    eof                             { exit 17 }
}

expect eof
exit 0
TCLEOF

            expect "$TCL_P1B" >> "$NODE_LOG" 2>&1
            local P1B_RC=$?
            rm -f "$TCL_P1B"

            echo "" >> "$NODE_LOG"
            echo "--- [Phase 1b Exit Code: $P1B_RC] ---" >> "$NODE_LOG"

            if [[ $P1B_RC -eq 0 ]]; then
                STATUS="SUCCESS"
                REASON="Password Set Directly via IPOS CLI (PATH B)"
                echo "Final Status: SUCCESS (PATH B - direct config route)" >> "$NODE_LOG"
            else
                case "$P1B_RC" in
                10) REASON="SSH Timeout — Phase 1b (ebdmots fallback login)";;
                11) REASON="Connection Refused — Phase 1b";;
                12) REASON="No Route to Host — Phase 1b";;
                13) REASON="Wrong ebdmots/Temp Password — Phase 1b";;
                17) REASON="Connection Closed — Phase 1b";;
                51) REASON="IPOS CLI Prompt Timeout — Phase 1b";;
                52) REASON="IPOS Validation Failed — Phase 1b";;
                53) REASON="IPOS Commit Failed — Phase 1b";;
                 *) REASON="Phase 1b Unexpected Error (exit code: $P1B_RC)";;
                esac
                echo "Final Status: FAILED ($REASON)" >> "$NODE_LOG"
            fi

        else
            # ── Phase 2 real failure ──────────────────────────
            case "$P2_RC" in
            10) REASON="SSH Timeout — Phase 2 (login as ${USERNAME})";;
            11) REASON="Connection Refused — Phase 2";;
            12) REASON="No Route to Host — Phase 2";;
            13) REASON="Wrong Temp Password / ${USERNAME} Auth Failed — Phase 2";;
            17) REASON="Connection Closed — Phase 2";;
            20) REASON="New Password Rejected (bad/weak/policy) — Phase 2";;
            22) REASON="New Passwords Did Not Match — Phase 2";;
            61) REASON="Password-Change Prompt Timeout — Phase 2 PATH A";;
             *) REASON="Phase 2 Unexpected Error (exit code: $P2_RC)";;
            esac
            echo "Final Status: FAILED ($REASON)" >> "$NODE_LOG"
        fi

        break
    done

    # Write result row to output CSV
    echo "\"$NODE_IP\",\"$NODE_TYPE\",\"$USERNAME\",\"$STATUS\",\"$REASON\",$ATTEMPT,\"$(date '+%F %T')\",\"$NODE_LOG\"" \
        >> "$OUTPUT_CSV"

    printf "[%s] Node: %-20s | User: %-12s | Status: %-10s | Reason: %s\n" \
        "$(date '+%T')" "$NODE_IP" "$USERNAME" "$STATUS" "$REASON"
}

# ==============================================================
# PARALLEL WORKER LOOP
# ==============================================================
export -f process_node generate_temp_pass
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

