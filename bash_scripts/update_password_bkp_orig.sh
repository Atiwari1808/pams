#!/bin/bash
# ============================================================
# Script  : update_password.sh
# Purpose : Update node user passwords in remote DB servers.
#           Called by Django views.py (_run_script) as:
#             bash update_password.sh <input_csv> <output_csv>
#
# Args    : $1 = absolute path to input CSV
#           $2 = absolute path to output CSV (results)
#
# Input CSV format ($1):
#   node_ip,username,old_password,new_password
#
#   - node_ip     : real IP address  --> Mode A (update by ip+username)
#                   "NA"             --> Mode B (update by username+old_password)
#   - old_password: current password as user knows it (plain or Base64)
#   - new_password: desired new password (plain or Base64)
#
# Output CSV ($2):
#   node_ip,username,db_server,db_name,password_format,status,remarks
#
# db_servers.csv format (same dir as script):
#   server_ip,ssh_user,ssh_pass,db_user,db_pass,db_name
#
# Password format handling (done entirely in bash):
#   The script fetches the current stored password from the DB to
#   detect the storage format:
#     - If stored value is valid Base64  --> DB uses Base64 storage
#         * new_password is Base64-encoded before writing
#         * old_password is Base64-encoded for WHERE matching (Mode B)
#     - Otherwise                        --> DB uses PlainText storage
#         * new_password is written as-is
#         * old_password is used as-is for WHERE matching (Mode B)
#
# Modes:
#   Mode A -- node_ip is a real IP:
#             One batched UPDATE per DB server:
#             UPDATE ... SET password=? WHERE username=? AND ip IN (...)
#   Mode B -- node_ip is "NA":
#             UPDATE ... SET password=? WHERE username=? AND password=old_pw
#
# Exit    : 0 = completed (output file written)
#           1 = fatal error (missing args / deps / files)
#
# FIX 1 (2026-03-27):
#   All log() output now goes to stderr (>&2).
#   Previously log() wrote to stdout, which caused command-substitution
#   callers (resolve_passwords, detect_db_format, etc.) to capture log
#   lines as part of their return values -- resulting in log text being
#   written into the DB password column instead of the actual password.
#
# FIX 2 (2026-03-27):
#   resolve_passwords returns two lines (new_pw on line 1, old_pw on
#   line 2). The previous code used:
#     IFS=$'\n' read -r db_new_pw db_old_pw <<< "$(resolve_passwords ...)"
#   A here-string (<<<) feeds only one line to read, so db_old_pw was
#   always empty -- causing Mode B pre-check to match 0 rows and skip.
#   Fixed by capturing the full output into a variable, then extracting
#   each line with sed -n '1p' / sed -n '2p'. Applied in both Mode A
#   and Mode B.
# ============================================================

# NOTE: No 'set -e' -- we handle all errors explicitly so Django
#       gets meaningful logs rather than silent early exits.

# -- Args ------------------------------------------------------
NEW_PASSWORDS_CSV="${1:-}"
RESULT_CSV="${2:-}"

if [[ -z "$NEW_PASSWORDS_CSV" || -z "$RESULT_CSV" ]]; then
    echo "[ERROR] Usage: bash update_password.sh <input_csv> <output_csv>" >&2
    exit 1
fi

if [[ ! -f "$NEW_PASSWORDS_CSV" ]]; then
    echo "[ERROR] Input file not found: ${NEW_PASSWORDS_CSV}" >&2
    exit 1
fi

# -- Paths derived from script location -----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_SERVERS_CSV="${SCRIPT_DIR}/db_servers.csv"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/update_password_${TIMESTAMP}.log"

# Ensure output directory exists
mkdir -p "$(dirname "${RESULT_CSV}")"

# -- Colors (only when stderr is a terminal) -------------------
if [ -t 2 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# -- Logger ----------------------------------------------------
# All echo calls go to stderr (>&2).
# Functions that return values via $(...) command substitution
# must only write to stdout for their return value; everything
# else (logging) goes to stderr to keep stdout clean.
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
    case "$level" in
        INFO)  echo -e "${CYAN}[${ts}] [INFO]  ${msg}${NC}" >&2 ;;
        OK)    echo -e "${GREEN}[${ts}] [OK]    ${msg}${NC}" >&2 ;;
        WARN)  echo -e "${YELLOW}[${ts}] [WARN]  ${msg}${NC}" >&2 ;;
        ERROR) echo -e "${RED}[${ts}] [ERROR] ${msg}${NC}" >&2 ;;
        DEBUG) echo    "[${ts}] [DEBUG] ${msg}" >&2 ;;
    esac
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
    if [[ -n "${SRV_LOG_FILE:-}" ]]; then
        echo "[${ts}] [${level}] ${msg}" >> "${SRV_LOG_FILE}"
    fi
}

# -- ASCII sanitizer -------------------------------------------
# Strips non-printable / non-ASCII bytes so remote MySQL error
# messages (smart quotes, 0x97, etc.) never corrupt the output
# CSV which Django reads as UTF-8.
sanitize_ascii() {
    printf '%s' "$1" | tr -cd '[:print:]\t'
}

# -- Pre-flight ------------------------------------------------
check_deps() {
    local missing=0
    for cmd in expect ssh mysql base64; do
        command -v "$cmd" &>/dev/null || { log ERROR "Missing command: $cmd"; missing=1; }
    done
    [[ $missing -eq 1 ]] && { log ERROR "Install missing deps and re-run."; exit 1; }
}

check_files() {
    if [[ ! -f "$DB_SERVERS_CSV" ]]; then
        log ERROR "DB servers config not found: ${DB_SERVERS_CSV}"
        log ERROR "Place db_servers.csv in the same directory as this script: ${SCRIPT_DIR}"
        exit 1
    fi
}

init_result_csv() {
    echo "node_ip,username,db_server,db_name,password_format,status,remarks" > "${RESULT_CSV}"
    log INFO "Result CSV : ${RESULT_CSV}"
}

append_result() {
    # $1=node_ip $2=username $3=db_server $4=db_name
    # $5=fmt     $6=status   $7=remarks
    local remarks; remarks=$(sanitize_ascii "$7")
    echo "\"$1\",\"$2\",\"$3\",\"$4\",\"$5\",\"$6\",\"${remarks}\"" >> "${RESULT_CSV}"
}

# -- IP validation ---------------------------------------------
is_valid_ip() {
    local ip="$1"
    
    # Check for IPv4
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
        local c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
        [[ $a -le 255 && $b -le 255 && $c -le 255 && $d -le 255 ]]
        return $?
    # Check for Basic IPv6
    elif [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *":"* ]]; then
        return 0
    else
        return 1
    fi
}

# -- Base64 detection ------------------------------------------
is_base64() {
    local val="$1"
    [[ -z "$val" ]] && return 1
    echo "$val" | grep -qE '^[A-Za-z0-9+/]+=*$' || return 1
    local len="${#val}"
    (( len % 4 != 0 )) && return 1
    local decoded
    decoded=$(echo "$val" | base64 -d 2>/dev/null)
    [[ $? -eq 0 && -n "$decoded" ]]
}

# -- Base64 encode a plain-text value --------------------------
to_base64() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

# -- SQL string escaping ---------------------------------------
sql_escape() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//\'/\'\'}"
    printf '%s' "$val"
}

# --------------------------------------------------------------
# run_remote_mysql
#   Transfers SQL via Base64 over SSH, runs mysql on
#   the remote host, returns stdout.
#   Uses non-interactive SSH execution to bypass terminal hangs.
# --------------------------------------------------------------
run_remote_mysql() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local sql_query="$7"

    local uid="${$}_${RANDOM}_$(date +%s%N)"
    local remote_sql="/tmp/.ms_${uid}.sql"
    local sentinel_start="__START_${uid}__"
    local sentinel_end="__END_${uid}__"

    local b64_sql
    b64_sql=$(printf '%s' "$sql_query" | base64 | tr -d '\n')

    local cmd_write="echo ${b64_sql} | base64 -d > ${remote_sql}"
    local safe_db_pass; safe_db_pass=$(sql_escape "$db_pass")
    
    # Bundle everything into a single command sequence passed directly to SSH.
    # We evaluate $? (the exit code of mysql) in the remote shell.
    local ssh_cmd="${cmd_write} ; echo ${sentinel_start} ; mysql -u${db_user} -p'${safe_db_pass}' ${db_name} < ${remote_sql} 2>&1 ; echo ${sentinel_end}_\$? ; rm -f ${remote_sql}"

    # Pass all variables to Expect via the environment to strictly prevent
    # Tcl substitution crashes (e.g., if a password contains $ or [).
    export EXPECT_SSH_IP="$server_ip"
    export EXPECT_SSH_USER="$ssh_user"
    export EXPECT_SSH_PASS="$ssh_pass"
    export EXPECT_SSH_CMD="$ssh_cmd"
    
    local raw_output
    raw_output=$(
        # The quotes around 'EXPECT_SCRIPT' prevent local Bash variable expansion
        expect -f - << 'EXPECT_SCRIPT'
log_user 0
set timeout 120

set ip   $env(EXPECT_SSH_IP)
set user $env(EXPECT_SSH_USER)
set pass $env(EXPECT_SSH_PASS)
set cmd  $env(EXPECT_SSH_CMD)

# Execute the command non-interactively using -T (disable TTY allocation).
# This operates exactly like your test_ssh function.
spawn ssh \
    -T \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 \
    "${user}@${ip}" "${cmd}"

expect {
    "yes/no"            { send "yes\r"; exp_continue }
    -nocase "password:" { send "${pass}\r"; exp_continue }
    eof                 { }
    timeout             { puts "EXPECT_ERR:ssh_or_mysql_timeout"; exit 1 }
}

puts "__OUTPUT_START__"
if {[info exists expect_out(buffer)]} {
    puts $expect_out(buffer)
}
puts "__OUTPUT_END__"
EXPECT_SCRIPT
    )
    
    # Cleanup environment variables
    unset EXPECT_SSH_IP EXPECT_SSH_USER EXPECT_SSH_PASS EXPECT_SSH_CMD

    if echo "$raw_output" | grep -q "EXPECT_ERR:"; then
        local err
        err=$(echo "$raw_output" | grep "EXPECT_ERR:" | head -1)
        log ERROR "Expect error on ${server_ip}: ${err}"
        return 1
    fi

    local mysql_rc
    mysql_rc=$(echo "$raw_output" | grep -oE "${sentinel_end}_[0-9]+" | awk -F'_' '{print $NF}' | tail -1)

    # Failsafe if the SSH command crashed before printing the sentinel
    if [[ -z "$mysql_rc" ]]; then
        log DEBUG "  [run_remote_mysql] Missing sentinel. Raw output: $(echo "$raw_output" | tr '\n' ' ')"
        return 1
    fi

    local sql_output
    sql_output=$(echo "$raw_output" \
        | sed -n "/${sentinel_start}/,/${sentinel_end}/p" \
        | grep -v "${sentinel_start}" \
        | grep -v "${sentinel_end}" \
        | grep -v -i "warning.*password" \
        | grep -v "^$" \
        | tr -d '\r')

    echo "$sql_output"
    return "${mysql_rc:-0}"
}

# -- Test SSH connectivity -------------------------------------
test_ssh() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local result
    result=$(
        expect -f - << EEXP 2>/dev/null
log_user 0
set timeout 20
spawn ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "${ssh_user}@${server_ip}" "echo __SSHOK__"
expect {
    "yes/no"            { send "yes\r"; exp_continue }
    -nocase "password:" { send "${ssh_pass}\r"; exp_continue }
    "__SSHOK__"         { puts "__SSHOK__" }
    timeout             { exit 1 }
    eof                 { }
}
expect eof
EEXP
    )
    echo "$result" | grep -q "__SSHOK__"
}

# --------------------------------------------------------------
# detect_db_format
#   Fetches one stored password row from the DB to determine
#   whether the DB stores passwords as Base64 or PlainText.
#
#   Returns via echo:  "Base64" | "PlainText" | "NOT_FOUND" | "UNKNOWN"
#   Return code      :  0 = query OK,  1 = query failed
#
#   node_ip arg is optional -- pass "" for Mode B (username-only lookup)
#
#   NOTE: Returns value via stdout only. All log() calls go to stderr.
# --------------------------------------------------------------
detect_db_format() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local uname="$7"     node_ip="$8"

    local sql out rc sample
    local safe_uname; safe_uname=$(sql_escape "$uname")

    # Try IP+username first (Mode A), fall back to username-only
    if [[ -n "$node_ip" ]]; then
        local safe_ip; safe_ip=$(sql_escape "$node_ip")
        sql="SELECT password FROM node_info WHERE ip='${safe_ip}' AND username='${safe_uname}' LIMIT 1;"
        out=$(run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                               "$db_user"   "$db_pass"  "$db_name" "$sql")
        rc=$?
        sample=$(echo "$out" \
            | grep -v -i '^password$' | grep -v -i 'warning' \
            | grep -v '^$' | head -1 | tr -d '\r\n')
        sample=$(sanitize_ascii "$sample")
        log DEBUG "  [detect_format] ip+uname query rc=${rc} sample='${sample}'"

        # Node not on this DB server -- tell caller cleanly
        if [[ $rc -eq 0 && -z "$sample" ]]; then
            echo "NOT_FOUND"
            return 0
        fi
    fi

    # Fallback: any row for this username (Mode B path or failed IP query)
    if [[ -z "$sample" ]]; then
        sql="SELECT password FROM node_info WHERE username='${safe_uname}' LIMIT 1;"
        out=$(run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                               "$db_user"   "$db_pass"  "$db_name" "$sql")
        rc=$?
        sample=$(echo "$out" \
            | grep -v -i '^password$' | grep -v -i 'warning' \
            | grep -v '^$' | head -1 | tr -d '\r\n')
        sample=$(sanitize_ascii "$sample")
        log DEBUG "  [detect_format] uname-only fallback rc=${rc} sample='${sample}'"
    fi

    if [[ $rc -ne 0 ]]; then
        echo "UNKNOWN"
        return 1
    fi

    if [[ -z "$sample" ]]; then
        echo "NOT_FOUND"
        return 0
    fi

    if is_base64 "$sample"; then
        echo "Base64"
    else
        echo "PlainText"
    fi
    return 0
}

# --------------------------------------------------------------
# resolve_passwords
#   Converts user-supplied plain-text passwords into the correct
#   format for the DB (Base64-encode if DB stores Base64).
#
#   Outputs two lines:
#     LINE 1: db_new_pw  (value to SET in UPDATE)
#     LINE 2: db_old_pw  (value to match in WHERE, Mode B only)
#
#   Callers must capture with:
#     local resolved
#     resolved=$(resolve_passwords "$fmt" "$old" "$new")
#     db_new_pw=$(echo "$resolved" | sed -n '1p')
#     db_old_pw=$(echo "$resolved" | sed -n '2p')
#
#   Do NOT use:  IFS=$'\n' read -r a b <<< "$(resolve_passwords ...)"
#   A here-string (<<<) only feeds one line to read, so b is always
#   empty.
#
#   NOTE: Returns values via stdout only. All log() calls go to stderr.
# --------------------------------------------------------------
resolve_passwords() {
    local fmt="$1" user_old_pw="$2" user_new_pw="$3"

    local db_new db_old

    if [[ "$fmt" == "Base64" ]]; then
        db_new=$(to_base64 "$user_new_pw")
        db_old=$(to_base64 "$user_old_pw")
        log DEBUG "  [resolve_pw] Base64 -> new='${db_new}'  old='${db_old}'"
    else
        db_new="$user_new_pw"
        db_old="$user_old_pw"
        log DEBUG "  [resolve_pw] PlainText -> new='${db_new}'  old='${db_old}'"
    fi

    echo "$db_new"
    echo "$db_old"
}

# --------------------------------------------------------------
# MODE A helpers
# --------------------------------------------------------------
update_password_batch_mode_a() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local uname="$7"     new_pw="$8"   ip_list_str="$9"

    local safe_uname; safe_uname=$(sql_escape "$uname")
    local safe_pw;    safe_pw=$(sql_escape "$new_pw")

    local in_clause=""
    for ip in $ip_list_str; do
        local safe_ip; safe_ip=$(sql_escape "$ip")
        if [[ -n "$in_clause" ]]; then
            in_clause="${in_clause},'${safe_ip}'"
        else
            in_clause="'${safe_ip}'"
        fi
    done

    local sql="UPDATE node_info SET password='${safe_pw}' WHERE username='${safe_uname}' AND ip IN (${in_clause});"
    log DEBUG "  [MODE A] UPDATE SQL: ${sql}"

    run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                     "$db_user"   "$db_pass"  "$db_name"  "$sql" \
                     >> "${SRV_LOG_FILE:-${LOG_FILE}}" 2>&1
    return $?
}

verify_batch_mode_a() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local uname="$7"     expected="$8" ip_list_str="$9"

    local safe_uname; safe_uname=$(sql_escape "$uname")
    local safe_exp;   safe_exp=$(sql_escape "$expected")

    local in_clause=""
    for ip in $ip_list_str; do
        local safe_ip; safe_ip=$(sql_escape "$ip")
        if [[ -n "$in_clause" ]]; then
            in_clause="${in_clause},'${safe_ip}'"
        else
            in_clause="'${safe_ip}'"
        fi
    done

    local total_ips; total_ips=$(echo "$ip_list_str" | wc -w | tr -d ' ')
    local sql="SELECT COUNT(*) FROM node_info WHERE username='${safe_uname}' AND password='${safe_exp}' AND ip IN (${in_clause});"
    local out count
    out=$(run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                           "$db_user"   "$db_pass"  "$db_name"  "$sql")
    count=$(echo "$out" \
        | grep -v -i '^count' | grep -v -i 'warning' \
        | grep -v '^$' | head -1 | tr -d '\r\n ')

    log DEBUG "  [MODE A] verify: expected=${total_ips} verified=${count}"
    echo "${count:-0}:${total_ips}"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count == total_ips ))
}

# --------------------------------------------------------------
# MODE B helpers
# --------------------------------------------------------------
update_password_by_old_pw() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local uname="$7"     new_pw="$8"   old_pw="$9"

    local safe_uname; safe_uname=$(sql_escape "$uname")
    local safe_new;   safe_new=$(sql_escape "$new_pw")
    local safe_old;   safe_old=$(sql_escape "$old_pw")
    local sql="UPDATE node_info SET password='${safe_new}' WHERE username='${safe_uname}' AND password='${safe_old}';"

    run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                     "$db_user"   "$db_pass"  "$db_name"  "$sql" \
                     >> "${SRV_LOG_FILE:-${LOG_FILE}}" 2>&1
    return $?
}

verify_password_by_uname() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local uname="$7"     expected="$8"

    local safe_uname; safe_uname=$(sql_escape "$uname")
    local safe_exp;   safe_exp=$(sql_escape "$expected")
    local sql="SELECT COUNT(*) FROM node_info WHERE username='${safe_uname}' AND password='${safe_exp}';"
    local out count
    out=$(run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                           "$db_user"   "$db_pass"  "$db_name"  "$sql")
    count=$(echo "$out" \
        | grep -v -i '^count' | grep -v -i 'warning' \
        | grep -v '^$' | head -1 | tr -d '\r\n ')

    log DEBUG "  [MODE B] verify: rows with new password for '${uname}': ${count}"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 ))
}

check_rows_affected_by_old_pw() {
    local server_ip="$1" ssh_user="$2" ssh_pass="$3"
    local db_user="$4"   db_pass="$5"  db_name="$6"
    local uname="$7"     old_pw="$8"

    local safe_uname; safe_uname=$(sql_escape "$uname")
    local safe_old;   safe_old=$(sql_escape "$old_pw")
    local sql="SELECT COUNT(*) FROM node_info WHERE username='${safe_uname}' AND password='${safe_old}';"
    local out count
    out=$(run_remote_mysql "$server_ip" "$ssh_user" "$ssh_pass" \
                           "$db_user"   "$db_pass"  "$db_name"  "$sql")
    count=$(echo "$out" \
        | grep -v -i '^count' | grep -v -i 'warning' \
        | grep -v '^$' | head -1 | tr -d '\r\n ')
    echo "${count:-0}"
}

# ==============================================================
# MAIN
# ==============================================================
main() {
    log INFO "========================================================"
    log INFO " Node Password Update in DB -- Started"
    log INFO " Timestamp   : ${TIMESTAMP}"
    log INFO " Input CSV   : ${NEW_PASSWORDS_CSV}"
    log INFO " Output CSV  : ${RESULT_CSV}"
    log INFO " Main Log    : ${LOG_FILE}"
    log INFO " DB Servers  : ${DB_SERVERS_CSV}"
    log INFO "========================================================"

    check_deps
    check_files
    init_result_csv

    # -- Load DB servers ----------------------------------------
    declare -a SRV_IP SRV_SSH_U SRV_SSH_P SRV_DB_U SRV_DB_P SRV_DB_N
    declare -A SSH_UP SRV_LOG
    local n=0
    while IFS=',' read -r sip su sp du dp dn; do
        sip=$(echo "$sip" | tr -d '\r ')
        [[ "$sip" == "server_ip" || -z "$sip" ]] && continue
        SRV_IP[$n]="$sip"
        SRV_SSH_U[$n]=$(echo "$su" | tr -d '\r ')
        SRV_SSH_P[$n]=$(echo "$sp" | tr -d '\r ')
        SRV_DB_U[$n]=$(echo "$du"  | tr -d '\r ')
        SRV_DB_P[$n]=$(echo "$dp"  | tr -d '\r ')
        SRV_DB_N[$n]=$(echo "$dn"  | tr -d '\r ')
        SRV_LOG[$n]="${LOG_DIR}/update_password_${TIMESTAMP}_srv_${sip}.log"
        n=$((n + 1))
    done < "$DB_SERVERS_CSV"

    if [[ $n -eq 0 ]]; then
        log ERROR "No DB servers loaded from ${DB_SERVERS_CSV} -- aborting."
        exit 1
    fi
    log INFO "Loaded ${n} DB server(s)"

    # -- Pre-test SSH -------------------------------------------
    log INFO "Testing SSH connectivity ..."
    for i in "${!SRV_IP[@]}"; do
        SRV_LOG_FILE="${SRV_LOG[$i]}"
        if test_ssh "${SRV_IP[$i]}" "${SRV_SSH_U[$i]}" "${SRV_SSH_P[$i]}"; then
            log OK   "  SSH OK  - ${SRV_IP[$i]}  (log: ${SRV_LOG[$i]})"
            SSH_UP[$i]=1
        else
            log WARN "  SSH FAIL - ${SRV_IP[$i]}"
            SSH_UP[$i]=0
        fi
        SRV_LOG_FILE=""
    done

    # -----------------------------------------------------------
    # Parse input CSV -- 4 columns:
    #   node_ip, username, old_password, new_password
    # -----------------------------------------------------------
    declare -A MODE_A_GROUPS MODE_A_DATA
    declare -a MODE_B_ROWS ROW_ORDER_A

    while IFS=',' read -r node_ip uname old_pw new_pw; do
        node_ip=$(echo "$node_ip" | tr -d '\r' | xargs)
        uname=$(echo "$uname"     | tr -d '\r' | xargs)
        old_pw=$(echo "$old_pw"   | tr -d '\r' | xargs)
        new_pw=$(echo "$new_pw"   | tr -d '\r' | xargs)

        [[ "$node_ip" == "node_ip" || -z "$node_ip" ]] && continue
        [[ -z "$uname" ]] && continue

        if [[ "${node_ip^^}" == "NA" ]]; then
            if [[ -z "$old_pw" ]]; then
                log WARN "  Skipping Mode B row: username='${uname}' -- old_password is empty"
                continue
            fi
            MODE_B_ROWS+=("${uname}|${old_pw}|${new_pw}")
        else
            if ! is_valid_ip "$node_ip"; then
                log WARN "  Skipping invalid IP: '${node_ip}' (username=${uname})"
                continue
            fi
            if [[ -z "${MODE_A_GROUPS[$uname]+x}" ]]; then
                MODE_A_GROUPS[$uname]="$node_ip"
                MODE_A_DATA[$uname]="${old_pw}|${new_pw}"
                ROW_ORDER_A+=("$uname")
            else
                if ! echo "${MODE_A_GROUPS[$uname]}" | grep -qw "$node_ip"; then
                    MODE_A_GROUPS[$uname]="${MODE_A_GROUPS[$uname]} ${node_ip}"
                fi
            fi
        fi
    done < "$NEW_PASSWORDS_CSV"

    log INFO "Mode A groups (unique usernames): ${#ROW_ORDER_A[@]}"
    log INFO "Mode B rows                     : ${#MODE_B_ROWS[@]}"

    local total=0 success=0 failed=0 skipped=0

    # ===========================================================
    # PROCESS MODE A
    # ===========================================================
    local seen_a=()
    for uname in "${ROW_ORDER_A[@]}"; do
        local already=0
        for s in "${seen_a[@]:-}"; do
            [[ "$s" == "$uname" ]] && { already=1; break; }
        done
        [[ $already -eq 1 ]] && continue
        seen_a+=("$uname")

        local ip_list="${MODE_A_GROUPS[$uname]}"
        local user_old_pw user_new_pw
        IFS='|' read -r user_old_pw user_new_pw <<< "${MODE_A_DATA[$uname]}"
        local ip_count; ip_count=$(echo "$ip_list" | wc -w | tr -d ' ')
        total=$((total + 1))

        log INFO "============================================================"
        log INFO "[MODE A] username='${uname}'  IPs=${ip_count}  [${ip_list}]"
        log INFO "  User supplied: new_password='${user_new_pw}'"

        for i in "${!SRV_IP[@]}"; do
            local db_s="${SRV_IP[$i]}"
            local ssh_u="${SRV_SSH_U[$i]}"
            local ssh_p="${SRV_SSH_P[$i]}"
            local db_u="${SRV_DB_U[$i]}"
            local db_p="${SRV_DB_P[$i]}"
            local db_n="${SRV_DB_N[$i]}"
            SRV_LOG_FILE="${SRV_LOG[$i]}"

            log INFO "  DB Server: ${db_s}  |  DB: ${db_n}"

            if [[ "${SSH_UP[$i]}" == "0" ]]; then
                log WARN "  Skipping -- SSH unavailable for ${db_s}"
                for ip in $ip_list; do
                    append_result "$ip" "$uname" "$db_s" "$db_n" \
                                  "UNKNOWN" "SKIPPED" "SSH to DB server failed at pre-check"
                    skipped=$((skipped + 1))
                done
                SRV_LOG_FILE=""; continue
            fi

            # -- Detect storage format --------------------------
            local first_ip; first_ip=$(echo "$ip_list" | awk '{print $1}')
            log INFO "  Detecting DB storage format via '${first_ip}' ..."
            local fmt
            fmt=$(detect_db_format "$db_s" "$ssh_u" "$ssh_p" \
                                   "$db_u" "$db_p" "$db_n" \
                                   "$uname" "$first_ip")
            local detect_rc=$?
            log INFO "  Detected format: ${fmt}"

            if [[ "$fmt" == "NOT_FOUND" ]]; then
                log WARN "  username/ip not found on ${db_s} -- skipping"
                for ip in $ip_list; do
                    append_result "$ip" "$uname" "$db_s" "$db_n" \
                                  "UNKNOWN" "SKIPPED" "username/ip not found in node_info on this DB server"
                    skipped=$((skipped + 1))
                done
                SRV_LOG_FILE=""; continue
            fi

            if [[ "$fmt" == "UNKNOWN" || $detect_rc -ne 0 ]]; then
                log ERROR "  Format detection failed (rc=${detect_rc}) on ${db_s}"
                for ip in $ip_list; do
                    append_result "$ip" "$uname" "$db_s" "$db_n" \
                                  "UNKNOWN" "FAILED" "DB format detection failed -- check DB credentials/connectivity"
                    failed=$((failed + 1))
                done
                SRV_LOG_FILE=""; continue
            fi

            # -- Resolve DB write value -------------------------
            # FIX: capture full two-line output first, then extract
            # each line with sed. Do NOT use IFS=$'\n' read with a
            # here-string (<<<) -- it only reads one line, leaving
            # db_old_pw empty.
            local resolved db_new_pw db_old_pw
            resolved=$(resolve_passwords "$fmt" "$user_old_pw" "$user_new_pw")
            db_new_pw=$(echo "$resolved" | sed -n '1p')
            db_old_pw=$(echo "$resolved" | sed -n '2p')
            log INFO "  DB write value (new): '${db_new_pw}'"

            # -- Batched UPDATE ----------------------------------
            log INFO "  Running batched UPDATE for ${ip_count} IP(s) ..."
            update_password_batch_mode_a "$db_s" "$ssh_u" "$ssh_p" \
                                          "$db_u" "$db_p" "$db_n" \
                                          "$uname" "$db_new_pw" "$ip_list"
            local upd_rc=$?

            if [[ $upd_rc -ne 0 ]]; then
                log ERROR "  Batched UPDATE failed (rc=${upd_rc})"
                for ip in $ip_list; do
                    append_result "$ip" "$uname" "$db_s" "$db_n" \
                                  "$fmt" "FAILED" "Batched UPDATE query failed rc=${upd_rc}"
                    failed=$((failed + 1))
                done
                SRV_LOG_FILE=""; continue
            fi

            # -- Verify -----------------------------------------
            log INFO "  Verifying ${ip_count} row(s) ..."
            local verify_result
            verify_result=$(verify_batch_mode_a "$db_s" "$ssh_u" "$ssh_p" \
                                                "$db_u" "$db_p" "$db_n" \
                                                "$uname" "$db_new_pw" "$ip_list")
            local verify_rc=$?
            local verified_count total_count
            verified_count=$(echo "$verify_result" | cut -d: -f1)
            total_count=$(echo "$verify_result"    | cut -d: -f2)

            if [[ "$verified_count" -gt 0 ]]; then
                if [[ "$verified_count" -eq "$total_count" ]]; then
                    log OK "  [MODE A] Verified -- ${verified_count} IPs -- ${db_s}/${db_n}"
                else
                    log WARN "  [MODE A] Partial verify: ${verified_count} out of ${total_count} IPs -- ${db_s}/${db_n}"
                fi
                
                for ip in $ip_list; do
                    append_result "$ip" "$uname" "$db_s" "$db_n" \
                                  "$fmt" "SUCCESS" \
                                  "MODE A: Updated ${verified_count} out of ${total_count} IPs"
                    success=$((success + 1))
                done
            else
                log ERROR "  Verification failed: 0 rows updated (expected=${total_count})"
                for ip in $ip_list; do
                    append_result "$ip" "$uname" "$db_s" "$db_n" \
                                  "$fmt" "FAILED" \
                                  "MODE A: UPDATE ran but 0 rows verified"
                    failed=$((failed + 1))
                done
            fi

            SRV_LOG_FILE=""
        done
    done

    # ===========================================================
    # PROCESS MODE B
    # ===========================================================
    for row in "${MODE_B_ROWS[@]:-}"; do
        [[ -z "$row" ]] && continue
        local uname user_old_pw user_new_pw
        IFS='|' read -r uname user_old_pw user_new_pw <<< "$row"
        total=$((total + 1))

        log INFO "============================================================"
        log INFO "[MODE B] username='${uname}'  (match by old password across all DB servers)"
        log INFO "  User supplied: old_password='${user_old_pw}'  new_password='${user_new_pw}'"

        for i in "${!SRV_IP[@]}"; do
            local db_s="${SRV_IP[$i]}"
            local ssh_u="${SRV_SSH_U[$i]}"
            local ssh_p="${SRV_SSH_P[$i]}"
            local db_u="${SRV_DB_U[$i]}"
            local db_p="${SRV_DB_P[$i]}"
            local db_n="${SRV_DB_N[$i]}"
            SRV_LOG_FILE="${SRV_LOG[$i]}"

            log INFO "  DB Server: ${db_s}  |  DB: ${db_n}"

            if [[ "${SSH_UP[$i]}" == "0" ]]; then
                log WARN "  Skipping -- SSH unavailable for ${db_s}"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "UNKNOWN" "SKIPPED" "SSH to DB server failed at pre-check"
                skipped=$((skipped + 1))
                SRV_LOG_FILE=""; continue
            fi

            # -- Detect storage format (username-only) ----------
            log INFO "  Detecting DB storage format for '${uname}' ..."
            local fmt
            fmt=$(detect_db_format "$db_s" "$ssh_u" "$ssh_p" \
                                   "$db_u" "$db_p" "$db_n" \
                                   "$uname" "")
            local detect_rc=$?
            log INFO "  Detected format: ${fmt}"

            if [[ "$fmt" == "NOT_FOUND" ]]; then
                log WARN "  username='${uname}' not found on ${db_s} -- skipping"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "UNKNOWN" "SKIPPED" "username not found in node_info on this DB server"
                skipped=$((skipped + 1))
                SRV_LOG_FILE=""; continue
            fi

            if [[ "$fmt" == "UNKNOWN" || $detect_rc -ne 0 ]]; then
                log ERROR "  Format detection failed (rc=${detect_rc}) on ${db_s}"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "UNKNOWN" "FAILED" "DB format detection failed -- check DB credentials/connectivity"
                failed=$((failed + 1))
                SRV_LOG_FILE=""; continue
            fi

            # -- Resolve DB values ------------------------------
            # FIX: capture full two-line output first, then extract
            # each line with sed. Do NOT use IFS=$'\n' read with a
            # here-string (<<<) -- it only reads one line, leaving
            # db_old_pw empty, causing the pre-check to match 0 rows.
            local resolved db_new_pw db_old_pw
            resolved=$(resolve_passwords "$fmt" "$user_old_pw" "$user_new_pw")
            db_new_pw=$(echo "$resolved" | sed -n '1p')
            db_old_pw=$(echo "$resolved" | sed -n '2p')
            log INFO "  DB match value (old): '${db_old_pw}'"
            log INFO "  DB write value (new): '${db_new_pw}'"

            # -- Pre-check: rows matching old password ----------
            log INFO "  Pre-check: counting rows matching old password ..."
            local match_count
            match_count=$(check_rows_affected_by_old_pw \
                            "$db_s" "$ssh_u" "$ssh_p" \
                            "$db_u" "$db_p" "$db_n" \
                            "$uname" "$db_old_pw")
            log INFO "  Rows matching old password: ${match_count}"

            if [[ "$match_count" == "0" || -z "$match_count" ]]; then
                log WARN "  No rows matched username+old_password -- skipping"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "$fmt" "SKIPPED" "no rows matched username+old_password on this DB server"
                skipped=$((skipped + 1))
                SRV_LOG_FILE=""; continue
            fi

            # -- UPDATE -----------------------------------------
            log INFO "  Running UPDATE for ${match_count} row(s) ..."
            update_password_by_old_pw "$db_s" "$ssh_u" "$ssh_p" \
                                       "$db_u" "$db_p" "$db_n" \
                                       "$uname" "$db_new_pw" "$db_old_pw"
            local upd_rc=$?

            if [[ $upd_rc -ne 0 ]]; then
                log ERROR "  UPDATE failed (rc=${upd_rc})"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "$fmt" "FAILED" "MODE B: UPDATE query failed rc=${upd_rc}"
                failed=$((failed + 1))
                SRV_LOG_FILE=""; continue
            fi

            # -- Verify -----------------------------------------
            log INFO "  Verifying ..."
            if verify_password_by_uname "$db_s" "$ssh_u" "$ssh_p" \
                                         "$db_u" "$db_p" "$db_n" \
                                         "$uname" "$db_new_pw"; then
                log OK "  [MODE B] Updated ${match_count} row(s) & verified -- ${db_s}/${db_n}"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "$fmt" "SUCCESS" \
                              "MODE B: updated ${match_count} row(s) by username+old_password"
                success=$((success + 1))
            else
                log ERROR "  [MODE B] Post-update verification failed"
                append_result "NA" "$uname" "$db_s" "$db_n" \
                              "$fmt" "FAILED" \
                              "MODE B: UPDATE ran but new password not found in verify"
                failed=$((failed + 1))
            fi

            SRV_LOG_FILE=""
        done
    done

    # -- Summary -----------------------------------------------
    log INFO "========================================================"
    log INFO " SUMMARY"
    log INFO "  Total groups/entries : ${total}"
    log OK   "  Successful           : ${success}"
    log WARN "  Skipped              : ${skipped}"
    [[ $failed -gt 0 ]] \
        && log ERROR "  Failed               : ${failed}" \
        || log INFO  "  Failed               : ${failed}"
    log INFO ""
    log INFO "  Output CSV : ${RESULT_CSV}"
    log INFO "  Main log   : ${LOG_FILE}"
    log INFO "  Per-server logs in : ${LOG_DIR}/"
    log INFO "========================================================"

    if [[ -f "${RESULT_CSV}" ]]; then
        exit 0
    else
        log ERROR "Output CSV was not created -- exiting with error."
        exit 1
    fi
}

main "$@"