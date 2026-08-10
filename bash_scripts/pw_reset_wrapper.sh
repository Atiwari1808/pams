#!/bin/bash
# ============================================================
# pw_reset_wrapper.sh  –  PAMS Password Reset Orchestrator
# ============================================================
# PURPOSE
#   Thin wrapper around existing SSH reset scripts
#   (mme_password_reset.sh, dns_password_reset.sh,
#    wmg_password_reset.sh, cmm_password_reset.sh).
#
#   Adds BEFORE the real script runs:
#     1. Auto-fetch old password from PAMS SQLite DB if missing
#     2. Auto-generate new password if missing
#
#   Adds AFTER the real script finishes (per node, SUCCESS only):
#     3. Update PAMS SQLite DB with new password + reset date
#
#   EXISTING SCRIPTS ARE NOT MODIFIED.
#   This wrapper pre-processes the input CSV, passes an
#   enriched CSV to the real script, then post-processes
#   the output CSV to update the DB and enhance the report.
#
# USAGE
#   Called by Django views.py _run_script() exactly the same as before:
#     bash pw_reset_wrapper.sh <target_script> <input.csv> <output.csv>
#
#   Or via settings.py RESET_PASSWORD_SCRIPTS:
#     'dns': 'pw_reset_wrapper.sh dns_password_reset.sh'
#
# INPUT CSV FORMAT (unchanged from existing scripts):
#   NodeIP,NodeType,Username,OldPassword,NewPassword
#   (OldPassword and/or NewPassword may be blank)
#
# OUTPUT CSV FORMAT (compatible superset):
#   NodeIP,NodeType,Username,Status,Reason,Attempts,Timestamp,LogFile,
#   OldPwSource,NewPwSource,DBUpdateStatus
#
# DEPENDENCIES
#   - python3 with sqlite3 (stdlib)
#   - pw_utils.py in same directory as this script
#   - The target reset script in same directory
#
# EXIT CODES
#   0  output CSV written (even if some nodes failed)
#   1  fatal pre-flight error
# ============================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_UTILS="${SCRIPT_DIR}/pw_utils.py"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="${SCRIPT_DIR}/logs"
SCRIPT_NAME="$(basename "$0" .sh)"
if [[ -n "${JOB_LOG_DIR:-}" ]]; then
    LOG_DIR="$JOB_LOG_DIR"
else
    LOG_DIR="${SCRIPT_DIR}/../media/logs/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$LOG_DIR"

WRAPPER_LOG="${LOG_DIR}/pw_reset_wrapper_${TIMESTAMP}.log"
ENHANCED_LOG="${LOG_DIR}/pw_reset_enhanced_${TIMESTAMP}.log"

# ---- Logging -------------------------------------------------------
wlog() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${ts}] [${level}] ${msg}" | tee -a "${WRAPPER_LOG}" >&2
}

# ---- Args ----------------------------------------------------------
if [[ $# -lt 3 ]]; then
    wlog ERROR "Usage: bash pw_reset_wrapper.sh <target_script.sh> <input.csv> <output.csv>"
    exit 1
fi

TARGET_SCRIPT="${SCRIPT_DIR}/${1}"
INPUT_CSV="$2"
OUTPUT_CSV="$3"

wlog INFO "======================================================"
wlog INFO " PAMS Password Reset Wrapper"
wlog INFO " Target script : ${TARGET_SCRIPT}"
wlog INFO " Input CSV     : ${INPUT_CSV}"
wlog INFO " Output CSV    : ${OUTPUT_CSV}"
wlog INFO " Wrapper log   : ${WRAPPER_LOG}"
wlog INFO "======================================================"

# ---- Pre-flight checks ---------------------------------------------
if [[ ! -f "${TARGET_SCRIPT}" ]]; then
    wlog ERROR "Target script not found: ${TARGET_SCRIPT}"
    exit 1
fi
if [[ ! -f "${INPUT_CSV}" ]]; then
    wlog ERROR "Input CSV not found: ${INPUT_CSV}"
    exit 1
fi
if [[ ! -f "${PW_UTILS}" ]]; then
    wlog ERROR "pw_utils.py not found at: ${PW_UTILS}"
    exit 1
fi
command -v python3 &>/dev/null || { wlog ERROR "python3 not found in PATH"; exit 1; }

# ---- Step 1: Pre-process input CSV via pw_utils.py -----------------
# Produce an enriched CSV where blank OldPassword / NewPassword fields
# are filled in, and we record the source for each.
# We also produce a JSON sidecar file mapping (ip,user) → context.

ENRICHED_CSV=$(mktemp --suffix=.csv)
SIDECAR_JSON=$(mktemp --suffix=.json)

wlog INFO "Pre-processing input CSV (auto-fetch/auto-generate) ..."

python3 - <<'PYEOF' "$INPUT_CSV" "$ENRICHED_CSV" "$SIDECAR_JSON" "$SCRIPT_DIR" "$WRAPPER_LOG" 2>>"${WRAPPER_LOG}"
import sys, csv, json, os, datetime
from pathlib import Path

input_csv   = sys.argv[1]
enriched    = sys.argv[2]
sidecar     = sys.argv[3]
script_dir  = sys.argv[4]
wrapper_log = sys.argv[5]

sys.path.insert(0, script_dir)
import pw_utils

# ----------------------------------------------------------------
# BATCH PASSWORD: generate ONE password for ALL nodes in this run.
# Each row that already has a NewPassword in input uses that value.
# Rows without NewPassword all get the SAME auto-generated password.
# ----------------------------------------------------------------

# First pass: read all rows, check who needs auto-generation
rows_data   = []
orig_fields = []
field_map   = {}

with open(input_csv, newline="", encoding="utf-8-sig") as fin:
    reader      = csv.DictReader(fin)
    orig_fields = reader.fieldnames or []
    field_map   = {f.strip().lower(): f for f in orig_fields}

    def get_field(row, *candidates):
        for c in candidates:
            k = field_map.get(c)
            if k and k in row:
                return (row[k] or "").strip()
        return ""

    for row in reader:
        rows_data.append(row)

needs_auto = any(
    not get_field(r, "newpassword", "new_password", "newpass")
    for r in rows_data
    if get_field(r, "nodeip", "node_ip", "ip")
)

# Generate once for the whole batch
batch_new_pw = ""
if needs_auto:
    batch_new_pw = pw_utils.generate_batch_password()
    pw_utils.set_batch_password(batch_new_pw)

    # Log prominently to wrapper log so password is always recoverable
    sep = "=" * 60
    ts  = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(wrapper_log, "a", encoding="utf-8") as wl:
        wl.write("\n" + sep + "\n")
        wl.write("[{}] [BATCH-PW] *** AUTO-GENERATED PASSWORD FOR THIS RUN ***\n".format(ts))
        wl.write("[{}] [BATCH-PW] PASSWORD = {}\n".format(ts, batch_new_pw))
        wl.write("[{}] [BATCH-PW] Applied to ALL nodes without an explicit NewPassword.\n".format(ts))
        wl.write("[{}] [BATCH-PW] Save this if any node is not tracked in PAMS DB.\n".format(ts))
        wl.write(sep + "\n\n")
    print("[BATCH-PW] Single batch password generated and logged.", file=sys.stderr)

# Second pass: resolve passwords and write enriched CSV
contexts = {}

with open(enriched, "w", newline="", encoding="utf-8") as fout:
    writer = csv.writer(fout)
    writer.writerow(["NodeIP", "NodeType", "Username", "OldPassword", "NewPassword"])

    for row in rows_data:
        ip       = get_field(row, "nodeip", "node_ip", "ip")
        ntype    = get_field(row, "nodetype", "node_type", "type")
        username = get_field(row, "username", "user")
        old_pw   = get_field(row, "oldpassword", "old_password", "oldpass")
        new_pw   = get_field(row, "newpassword", "new_password", "newpass")

        if not ip or not username:
            continue

        ctx = pw_utils.resolve_passwords_for_node(ip, username, old_pw, new_pw)
        key = "{}::{}".format(ip, username)
        contexts[key] = {
            "node_ip":        ctx.node_ip,
            "username":       ctx.username,
            "old_pw_source":  ctx.old_pw_source,
            "new_pw_source":  ctx.new_pw_source,
            "old_password":   ctx.old_password,
            "new_password":   ctx.new_password,
            "error_reason":   ctx.error_reason,
            "reset_status":   ctx.reset_status,
            "batch_password": batch_new_pw,
        }

        if ctx.reset_status == "SKIPPED":
            pw_utils._log.warning("Skipping ip=%s user=%s: %s", ip, username, ctx.error_reason)
            writer.writerow([ip, ntype, username, "", ""])
        else:
            writer.writerow([ip, ntype, username, ctx.old_password, ctx.new_password])

with open(sidecar, "w", encoding="utf-8") as sf:
    json.dump(contexts, sf, indent=2)

print("Pre-processed {} node(s). Batch pw: {}".format(len(contexts), bool(batch_new_pw)), file=sys.stderr)
sys.exit(0)
PYEOF

if [[ $PREPROCESS_RC -ne 0 ]]; then
    wlog ERROR "Pre-processing failed (rc=${PREPROCESS_RC}) – aborting"
    rm -f "${ENRICHED_CSV}" "${SIDECAR_JSON}"
    exit 1
fi

wlog INFO "Pre-processing complete. Enriched CSV: ${ENRICHED_CSV}"
wlog INFO "Sidecar contexts: ${SIDECAR_JSON}"

# ---- Step 2: Run the actual reset script ---------------------------
REAL_OUTPUT_CSV=$(mktemp --suffix=.csv)
wlog INFO "Running target script: ${TARGET_SCRIPT}"
wlog INFO "  args: ${ENRICHED_CSV}  ${REAL_OUTPUT_CSV}"

bash "${TARGET_SCRIPT}" "${ENRICHED_CSV}" "${REAL_OUTPUT_CSV}" 2>>"${WRAPPER_LOG}"
SCRIPT_RC=$?

wlog INFO "Target script finished with rc=${SCRIPT_RC}"

if [[ ! -f "${REAL_OUTPUT_CSV}" ]]; then
    wlog ERROR "Target script did not produce output CSV: ${REAL_OUTPUT_CSV}"
    rm -f "${ENRICHED_CSV}" "${SIDECAR_JSON}" "${REAL_OUTPUT_CSV}"
    exit 1
fi

# ---- Step 3: Post-process – DB update + enhanced report ------------
wlog INFO "Post-processing: DB update + enhanced report generation ..."

python3 - <<'PYEOF' "$REAL_OUTPUT_CSV" "$SIDECAR_JSON" "$OUTPUT_CSV" "$SCRIPT_DIR" "$ENHANCED_LOG" 2>>"${WRAPPER_LOG}"
import sys, csv, json, datetime
from pathlib import Path

real_output  = sys.argv[1]
sidecar_path = sys.argv[2]
final_output = sys.argv[3]
script_dir   = sys.argv[4]
enhanced_log = sys.argv[5]

sys.path.insert(0, script_dir)
import pw_utils

log = pw_utils.get_pams_logger("pw_post")

# Load sidecar
try:
    with open(sidecar_path, encoding="utf-8") as sf:
        contexts = json.load(sf)
except Exception as e:
    log.error("Cannot load sidecar JSON: %s", e)
    sys.exit(1)

# Open enhanced log for this run
elog = open(enhanced_log, "a", encoding="utf-8")
def elog_write(msg):
    ts = datetime.datetime.utcnow().isoformat(timespec="seconds")
    line = f"[{ts}] {msg}"
    elog.write(line + "\n")
    log.info(msg)

elog_write("=" * 60)
elog_write(" PAMS Enhanced Post-Processing Log")
elog_write(f" Source output : {real_output}")
elog_write(f" Sidecar       : {sidecar_path}")
elog_write(f" Final output  : {final_output}")
elog_write("=" * 60)

# Read target script output
try:
    with open(real_output, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        orig_rows = list(reader)
        orig_fields = reader.fieldnames or []
except Exception as e:
    log.error("Cannot read target script output: %s", e)
    sys.exit(1)

# Enhanced fields appended to existing columns
extra_fields = ["OldPwSource", "NewPwSource", "DBUpdateStatus", "DBUpdateRemark"]
out_fields   = list(orig_fields) + extra_fields

db_success_count = 0
db_fail_count    = 0
db_skip_count    = 0

enhanced_rows = []

for row in orig_rows:
    # Normalize: strip whitespace from all values
    row = {k: (v or "").strip() for k, v in row.items()}

    # Detect node identity – field names vary by script
    node_ip  = row.get("NodeIP") or row.get("node_ip") or row.get("IP") or ""
    username = row.get("Username") or row.get("username") or row.get("USER") or ""
    status   = row.get("Status") or row.get("status") or ""

    key = f"{node_ip}::{username}"
    ctx = contexts.get(key, {})

    old_pw_source   = ctx.get("old_pw_source", "UNKNOWN")
    new_pw_source   = ctx.get("new_pw_source", "UNKNOWN")
    new_password    = ctx.get("new_password", "")
    ctx_error       = ctx.get("error_reason", "")

    db_update_status = "SKIPPED"
    db_update_remark = ""

    if status.upper() == "SUCCESS" and new_password and node_ip and username:
        # ---- Update DB after confirmed SUCCESS -------------------------
        try:
            updated = pw_utils.update_db_after_reset(node_ip, username, new_password)
            if updated:
                db_update_status = "SUCCESS"
                db_update_remark = "DB updated: password + last_password_reset_date"
                db_success_count += 1
                elog_write(f"DB UPDATE SUCCESS  ip={node_ip} user={username}")
            else:
                db_update_status = "NOT_FOUND"
                db_update_remark = "Node not in PAMS DB – DB not updated"
                db_skip_count    += 1
                elog_write(f"DB UPDATE NOT_FOUND ip={node_ip} user={username}")
        except Exception as exc:
            db_update_status = "FAILED"
            db_update_remark = f"DB update error: {exc}"
            db_fail_count    += 1
            elog_write(f"DB UPDATE FAILED  ip={node_ip} user={username} err={exc}")
            log.error("DB update failed ip=%s user=%s: %s", node_ip, username, exc)
    else:
        if status.upper() != "SUCCESS":
            db_update_remark = f"Reset was not SUCCESS (status={status}) – DB not touched"
        elif ctx_error:
            db_update_remark = f"Pre-processing error: {ctx_error}"
        else:
            db_update_remark = "No new password resolved – skipping DB update"
        db_skip_count += 1
        elog_write(f"DB UPDATE SKIP  ip={node_ip} user={username} reason={db_update_remark}")

    row["OldPwSource"]    = old_pw_source
    row["NewPwSource"]    = new_pw_source
    row["DBUpdateStatus"] = db_update_status
    row["DBUpdateRemark"] = db_update_remark
    enhanced_rows.append(row)

# Write final enhanced output CSV
with open(final_output, "w", newline="", encoding="utf-8") as fout:
    writer = csv.DictWriter(fout, fieldnames=out_fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(enhanced_rows)

elog_write("-" * 60)
elog_write(f"DB updates:  SUCCESS={db_success_count}  FAILED={db_fail_count}  SKIPPED/NOT_FOUND={db_skip_count}")
elog_write(f"Enhanced report written to: {final_output}")
elog_write("=" * 60)
elog.close()

log.info(
    "Post-processing complete: %d SUCCESS, %d FAILED, %d SKIPPED DB updates",
    db_success_count, db_fail_count, db_skip_count,
)
sys.exit(0 if db_fail_count == 0 else 0)   # always exit 0; failures are in report
PYEOF

POST_RC=$?
if [[ $POST_RC -ne 0 ]]; then
    wlog ERROR "Post-processing failed (rc=${POST_RC})"
    # Fallback: copy raw output so Django gets something
    cp "${REAL_OUTPUT_CSV}" "${OUTPUT_CSV}" 2>/dev/null
fi

# ---- Cleanup -------------------------------------------------------
rm -f "${ENRICHED_CSV}" "${SIDECAR_JSON}" "${REAL_OUTPUT_CSV}"

if [[ -f "${OUTPUT_CSV}" ]]; then
    wlog INFO "======================================================"
    wlog INFO " Wrapper complete. Final output: ${OUTPUT_CSV}"
    wlog INFO " Enhanced log: ${ENHANCED_LOG}"
    wlog INFO "======================================================"
    exit 0
else
    wlog ERROR "Final output CSV not found: ${OUTPUT_CSV}"
    exit 1
fi

