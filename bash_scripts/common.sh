#!/bin/bash
# ==============================================================
# bash_scripts/common.sh   (OPTION A — shared include)
# ==============================================================
# One shared file that every PAMS bash script sources to get a
# uniform: argument contract, log directory, log() function with
# levels, dependency check, and ASCII sanitizer.
#
# ── HOW TO USE in any script ──────────────────────────────────
#   Put these lines near the TOP of the script (after the shebang
#   and the script's own config like MAX_RETRY/TIMEOUT):
#
#       SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#       source "${SCRIPT_DIR}/common.sh"
#       pams_init "$@"            # validates args, sets LOG_DIR, checks deps
#
#   After pams_init you can rely on these being set:
#       INPUT_CSV    -> $1   (validated, file exists)
#       OUTPUT_CSV   -> $2
#       LOG_DIR      -> media/logs/<jobid>_<script>  (Django)
#                       media/logs/<script>_<timestamp>  (manual)
#       OUTPUT_LOG / ERROR_LOG / DEBUG_LOG  -> roll-up files in LOG_DIR
#
#   Then use:
#       log INFO  "message"
#       log WARN  "message"
#       log ERROR "message"
#       log DEBUG "message"
#       clean=$(sanitize_ascii "$raw")
# ==============================================================

# ── Colours (only when stderr is a terminal) ──────────────────
if [ -t 2 ]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[1;33m'
    C_CYN='\033[0;36m'; C_NC='\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_NC=''
fi

# ── Dependency check ──────────────────────────────────────────
# Usage: pams_check_deps expect ssh sshpass
pams_check_deps() {
    local missing=0 cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || {
            echo "[ERROR] Missing required command: $cmd" >&2
            missing=1
        }
    done
    [[ $missing -eq 1 ]] && { echo "[ERROR] Install missing deps and re-run." >&2; exit 1; }
}

# ── ASCII sanitizer (kills 0xa0 / smart-quote bytes) ──────────
sanitize_ascii() { printf '%s' "$1" | tr -cd '[:print:]\t'; }

# ── Log directory resolution — ALWAYS under media/logs/ ───────
# Django sets JOB_LOG_DIR -> media/logs/<jobid>_<script>
# Manual run        -> media/logs/<script>_<timestamp>
pams_resolve_log_dir() {
    local script_dir script_name media_logs
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    script_name="$(basename "${BASH_SOURCE[1]}" .sh)"
    media_logs="${script_dir}/../media/logs"

    if [[ -n "${JOB_LOG_DIR:-}" ]]; then
        LOG_DIR="$JOB_LOG_DIR"
    else
        LOG_DIR="${media_logs}/${script_name}_$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$LOG_DIR"

    OUTPUT_LOG="$LOG_DIR/output.log"
    ERROR_LOG="$LOG_DIR/error.log"
    DEBUG_LOG="$LOG_DIR/debug.log"
    : > "$OUTPUT_LOG"; : > "$ERROR_LOG"; : > "$DEBUG_LOG"
}

# ── Unified logger with levels ────────────────────────────────
# log INFO|OK|WARN|ERROR|DEBUG  "message"
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
    local line="[${ts}] [${level}] ${msg}"
    case "$level" in
        INFO)  echo -e "${C_CYN}${line}${C_NC}"; echo "$line" >> "$OUTPUT_LOG" ;;
        OK)    echo -e "${C_GRN}${line}${C_NC}"; echo "$line" >> "$OUTPUT_LOG" ;;
        WARN)  echo -e "${C_YEL}${line}${C_NC}" >&2; echo "$line" >> "$ERROR_LOG" ;;
        ERROR) echo -e "${C_RED}${line}${C_NC}" >&2; echo "$line" >> "$ERROR_LOG" ;;
        DEBUG) :  ;;  # debug goes only to debug.log (below), not console
        *)     echo "$line" ;;
    esac
    echo "$line" >> "$DEBUG_LOG"
}

# ── One-call initializer ──────────────────────────────────────
# pams_init "$@"  — call with the script's own "$@"
pams_init() {
    INPUT_CSV="${1:-}"
    OUTPUT_CSV="${2:-}"

    if [[ -z "$INPUT_CSV" || -z "$OUTPUT_CSV" ]]; then
        echo "Usage: $0 <input.csv> <output.csv>" >&2
        exit 1
    fi
    if [[ ! -f "$INPUT_CSV" ]]; then
        echo "Error: Input file not found: $INPUT_CSV" >&2
        exit 1
    fi

    OUTPUT_DIR="$(dirname "$OUTPUT_CSV")"
    mkdir -p "$OUTPUT_DIR"

    pams_resolve_log_dir
    log INFO "Script start — input=${INPUT_CSV} output=${OUTPUT_CSV}"
    log INFO "Log directory: ${LOG_DIR}"
}
