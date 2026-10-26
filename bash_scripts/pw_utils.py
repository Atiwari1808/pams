#!/usr/bin/env python3
"""
pw_utils.py  -  PAMS Password Reset Utility Layer
====================================================
Reusable helper module injected around existing reset scripts.
Does NOT modify any existing script logic.

Provides:
  1. generate_password()       - secure random password per policy
  2. fetch_password_from_db()  - pull current password from NodePasswordExpiry
  3. update_db_after_reset()   - write new password + reset date on success
  4. get_pams_logger()         - shared structured logger
  5. ResetContext              - standard class for one node's reset context
  6. resolve_passwords_for_node() - central decision: INPUT vs DB vs AUTO

Called by the enhanced wrapper scripts:
  - bash_scripts/pw_reset_wrapper.sh  (orchestrates SSH-based resets)
  - views.py hook after _run_script() succeeds (DB update)

CLI usage (standalone):
  python3 pw_utils.py gen-password
  python3 pw_utils.py fetch-password  <node_ip> <username>
  python3 pw_utils.py update-db       <node_ip> <username> <new_password>
  python3 pw_utils.py resolve         <node_ip> <username> [old_pw] [new_pw]

Exit codes:
  0  success
  1  error (message on stderr)
  2  not-found (node not in PAMS DB)
"""

import os
import sys
import json
import random
import string
import logging
import sqlite3
import datetime
import traceback
from pathlib import Path
from typing import Optional, Tuple

# ---------------------------------------------------------------------------
# Locate the PAMS Django project root from this script's location.
# This script lives in:  <project_root>/bash_scripts/pw_utils.py
# db.sqlite3 lives in:   <project_root>/db.sqlite3
# ---------------------------------------------------------------------------
_SCRIPT_DIR   = Path(__file__).resolve().parent
_PROJECT_ROOT = _SCRIPT_DIR.parent          # pams_project_v3/
_DB_PATH      = _PROJECT_ROOT / "db.sqlite3"
_LOG_DIR      = _PROJECT_ROOT / "bash_scripts" / "logs"
_LOG_DIR.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Table / column names confirmed from live DB schema inspection
# ---------------------------------------------------------------------------
_TABLE = "dashboard_nodepasswordexpiry"
_COL_IP   = "node_ip"
_COL_USER = "username"
_COL_PW   = "recent_password"
_COL_DATE = "last_password_reset_date"

# ---------------------------------------------------------------------------
# Password policy
# ---------------------------------------------------------------------------
_PW_LENGTH   = 12
_UPPER       = string.ascii_uppercase
_LOWER       = string.ascii_lowercase
_DIGITS      = string.digits
_ALLOWED_SPEC = "@_!#"          # ONLY these special chars allowed
# $, %, ^, &, *, etc. are forbidden

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

def get_pams_logger(name: str = "pw_utils") -> logging.Logger:
    """
    Returns a named logger writing to:
      - console  (INFO+)
      - bash_scripts/logs/pw_utils_YYYYMMDD.log  (DEBUG+)
    Thread-safe; call once per script.
    """
    log = logging.getLogger(name)
    if log.handlers:          # avoid duplicate handlers on re-import
        return log
    log.setLevel(logging.DEBUG)

    fmt = logging.Formatter(
        "[%(asctime)s] [%(levelname)-7s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    # Console
    ch = logging.StreamHandler(sys.stderr)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)
    log.addHandler(ch)

    # File (daily rotation via filename suffix)
    today = datetime.date.today().strftime("%Y%m%d")
    fh = logging.FileHandler(_LOG_DIR / f"pw_utils_{today}.log", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    log.addHandler(fh)

    return log


_log = get_pams_logger()

# ---------------------------------------------------------------------------
# 1. PASSWORD GENERATION
# ---------------------------------------------------------------------------

def generate_password() -> str:
    """
    Generates a cryptographically secure password satisfying PAMS policy:
      - Length = 12
      - At least 1 uppercase, 1 lowercase, 1 digit, 1 allowed special char
      - Allowed special chars: @ _ ! #
      - Forbidden: $ and all other specials
    Raises RuntimeError if generation fails after 100 attempts.
    """
    alphabet = _UPPER + _LOWER + _DIGITS + _ALLOWED_SPEC
    rng = random.SystemRandom()         # uses os.urandom() - cryptographically secure

    for attempt in range(100):
        pw = [
            rng.choice(_UPPER),
            rng.choice(_LOWER),
            rng.choice(_DIGITS),
            rng.choice(_ALLOWED_SPEC),
        ]
        # Fill remaining positions
        pw += [rng.choice(alphabet) for _ in range(_PW_LENGTH - 4)]
        rng.shuffle(pw)
        candidate = "".join(pw)

        # Validate (defensive - should always pass given construction above)
        if _validate_password(candidate):
            _log.debug("generate_password: generated after %d attempt(s)", attempt + 1)
            return candidate

    raise RuntimeError("Failed to generate a valid password after 100 attempts")


def _validate_password(pw: str) -> bool:
    """Returns True if pw satisfies PAMS policy."""
    if len(pw) != _PW_LENGTH:
        return False
    has_upper = any(c in _UPPER for c in pw)
    has_lower = any(c in _LOWER for c in pw)
    has_digit = any(c in _DIGITS for c in pw)
    has_spec  = any(c in _ALLOWED_SPEC for c in pw)
    # Forbidden chars: anything that's not in our alphabet
    allowed_set = set(_UPPER + _LOWER + _DIGITS + _ALLOWED_SPEC)
    no_forbidden = all(c in allowed_set for c in pw)
    return has_upper and has_lower and has_digit and has_spec and no_forbidden


# ---------------------------------------------------------------------------
# 2. DB FETCH - old password
# ---------------------------------------------------------------------------

def fetch_password_from_db(
    node_ip: str,
    username: str,
    db_path: Path = _DB_PATH,
) -> Optional[str]:
    """
    Looks up `recent_password` from dashboard_nodepasswordexpiry
    matching (node_ip, username).

    Returns:
      str   - the stored password (may be empty string if blank)
      None  - record not found
    Raises sqlite3.Error on DB connectivity failure.
    """
    _log.debug("fetch_password_from_db: ip=%s user=%s db=%s", node_ip, username, db_path)
    if not db_path.exists():
        raise FileNotFoundError(f"PAMS SQLite DB not found at {db_path}")

    conn = sqlite3.connect(str(db_path), timeout=10)
    try:
        cur = conn.cursor()
        cur.execute(
            f"SELECT {_COL_PW} FROM {_TABLE} "
            f"WHERE {_COL_IP} = ? AND {_COL_USER} = ? LIMIT 1",
            (node_ip, username),
        )
        row = cur.fetchone()
        if row is None:
            _log.debug("fetch_password_from_db: record NOT FOUND ip=%s user=%s", node_ip, username)
            return None
        pw = row[0] or ""
        _log.debug("fetch_password_from_db: found password (len=%d)", len(pw))
        return pw
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 3. DB UPDATE - write new password after successful SSH reset
# ---------------------------------------------------------------------------

def update_db_after_reset(
    node_ip: str,
    username: str,
    new_password: str,
    db_path: Path = _DB_PATH,
) -> bool:
    """
    Updates dashboard_nodepasswordexpiry after a SUCCESSFUL node reset:
      - SET recent_password = new_password
      - SET last_password_reset_date = today
      - WHERE node_ip = node_ip AND username = username

    Returns True on success, False if no rows were updated (node not found).
    Raises sqlite3.Error on DB failure.

    SAFE: Only called when SSH reset was confirmed successful.
    Failed resets must NOT call this function.
    """
    _log.debug(
        "update_db_after_reset: ip=%s user=%s db=%s", node_ip, username, db_path
    )
    if not db_path.exists():
        raise FileNotFoundError(f"PAMS SQLite DB not found at {db_path}")

    today = datetime.date.today().isoformat()   # YYYY-MM-DD
    conn = sqlite3.connect(str(db_path), timeout=10)
    try:
        cur = conn.cursor()
        cur.execute(
            f"UPDATE {_TABLE} "
            f"SET {_COL_PW} = ?, {_COL_DATE} = ?, updated_at = ? "
            f"WHERE {_COL_IP} = ? AND {_COL_USER} = ?",
            (new_password, today, datetime.datetime.utcnow().isoformat(), node_ip, username),
        )
        conn.commit()
        rows = cur.rowcount
        if rows == 0:
            _log.warning(
                "update_db_after_reset: no rows matched ip=%s user=%s - NOT in PAMS DB",
                node_ip, username,
            )
            return False
        _log.info(
            "update_db_after_reset: SUCCESS ip=%s user=%s rows=%d date=%s",
            node_ip, username, rows, today,
        )
        return True
    except sqlite3.Error as exc:
        conn.rollback()
        _log.error("update_db_after_reset: DB error: %s", exc)
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 4. ResetContext class (Modified for Python 3.6 Compatibility)
# ---------------------------------------------------------------------------

class ResetContext:
    """
    Carries all resolved password information for a single node.
    Populated by resolve_passwords_for_node() before the SSH reset.
    """
    def __init__(self, node_ip: str, username: str):
        self.node_ip = node_ip
        self.username = username
        
        # Source flags (for reporting)
        self.old_pw_source = ""   # "INPUT" | "DATABASE" | "NONE"
        self.new_pw_source = ""   # "INPUT" | "AUTO_GENERATED"
        
        # Resolved values
        self.old_password = ""
        self.new_password = ""
        
        # Runtime outcome (filled after reset attempt)
        self.reset_status = ""    # "SUCCESS" | "FAILED" | "SKIPPED"
        self.db_update_status = ""# "SUCCESS" | "FAILED" | "SKIPPED" | "N/A"
        self.error_reason = ""
        self.timestamp = datetime.datetime.utcnow().isoformat()


# ---------------------------------------------------------------------------
# 5. resolve_passwords_for_node - central decision logic
# ---------------------------------------------------------------------------

def generate_batch_password() -> str:
    """
    Generates ONE password for an entire batch of nodes.
    Use this when resetting multiple nodes in one job run --
    the same password is applied to all nodes in that batch.
    Always logs the generated password prominently so it can
    be recovered even if a node is not in the PAMS DB.
    """
    pw = generate_password()
    _log.info("=" * 60)
    _log.info("BATCH AUTO-GENERATED PASSWORD: %s", pw)
    _log.info("Keep this safe -- used for ALL nodes in this reset job.")
    _log.info("=" * 60)
    return pw


# Module-level shared password for current batch run.
# Set once by pw_reset_wrapper.sh pre-processor; reused for all nodes.
_BATCH_NEW_PASSWORD: str = ""


def set_batch_password(pw: str) -> None:
    """Called once at batch start to fix the new password for all nodes."""
    global _BATCH_NEW_PASSWORD
    _BATCH_NEW_PASSWORD = pw
    _log.info("Batch password set (len=%d). Will reuse for all nodes.", len(pw))


def resolve_passwords_for_node(
    node_ip:      str,
    username:     str,
    input_old_pw: str = "",   # "" means "not provided"
    input_new_pw: str = "",   # "" means "not provided"
    db_path:      Path = _DB_PATH,
) -> ResetContext:
    """
    Applies the PAMS automation rules:

      OLD password:
        - If input_old_pw provided - use it (source=INPUT)
        - Otherwise - fetch from PAMS DB (source=DATABASE)
          - If DB has no record or empty pw - source=NONE, warn

      NEW password:
        - If input_new_pw provided - use it (source=INPUT)
        - Otherwise - generate random secure password (source=AUTO_GENERATED)

    Returns a populated ResetContext. Never raises; errors are stored in
    ctx.error_reason and ctx.reset_status = "SKIPPED".
    """
    ctx = ResetContext(node_ip=node_ip, username=username)

    # ---- Resolve OLD password -----------------------------------------------
    if input_old_pw:
        ctx.old_password  = input_old_pw
        ctx.old_pw_source = "INPUT"
        _log.debug("resolve: ip=%s user=%s OLD=INPUT", node_ip, username)
    else:
        try:
            db_pw = fetch_password_from_db(node_ip, username, db_path)
        except Exception as exc:
            _log.error("resolve: DB fetch failed for ip=%s user=%s: %s", node_ip, username, exc)
            ctx.old_pw_source = "DATABASE"
            ctx.old_password  = ""
            ctx.error_reason  = f"DB fetch failed: {exc}"
            ctx.reset_status  = "SKIPPED"
            ctx.db_update_status = "N/A"
            return ctx

        if db_pw is None:
            _log.warning("resolve: ip=%s user=%s not in PAMS DB - no old password", node_ip, username)
            ctx.old_pw_source = "NONE"
            ctx.old_password  = ""
        elif db_pw == "":
            _log.warning("resolve: ip=%s user=%s PAMS DB password is blank", node_ip, username)
            ctx.old_pw_source = "DATABASE"
            ctx.old_password  = ""
        else:
            ctx.old_pw_source = "DATABASE"
            ctx.old_password  = db_pw
            _log.info("resolve: ip=%s user=%s OLD=DATABASE (from PAMS)", node_ip, username)

    # ---- Resolve NEW password -----------------------------------------------
    if input_new_pw:
        ctx.new_password  = input_new_pw
        ctx.new_pw_source = "INPUT"
        _log.debug("resolve: ip=%s user=%s NEW=INPUT", node_ip, username)
    else:
        try:
            # Use batch password if set (same password for all nodes in run)
            # Otherwise fall back to per-node generation
            if _BATCH_NEW_PASSWORD:
                ctx.new_password  = _BATCH_NEW_PASSWORD
                ctx.new_pw_source = "AUTO_GENERATED_BATCH"
                _log.info(
                    "resolve: ip=%s user=%s NEW=AUTO_GENERATED_BATCH (shared)",
                    node_ip, username,
                )
            else:
                ctx.new_password  = generate_password()
                ctx.new_pw_source = "AUTO_GENERATED"
                _log.info(
                    "resolve: ip=%s user=%s NEW=AUTO_GENERATED (per-node fallback)",
                    node_ip, username,
                )
        except Exception as exc:
            _log.error("resolve: password generation failed: %s", exc)
            ctx.new_pw_source = "AUTO_GENERATED"
            ctx.new_password  = ""
            ctx.error_reason  = f"Password generation failed: {exc}"
            ctx.reset_status  = "SKIPPED"
            ctx.db_update_status = "N/A"

    return ctx


# ---------------------------------------------------------------------------
# 6. Convenience: build enhanced CSV row for reporting
# ---------------------------------------------------------------------------

def build_report_row(ctx: ResetContext) -> dict:
    """
    Returns a dict matching the enhanced output CSV columns used by the
    wrapper scripts.  Compatible with existing columns plus new ones.
    """
    return {
        "node_ip":         ctx.node_ip,
        "username":        ctx.username,
        "old_pw_source":   ctx.old_pw_source,
        "new_pw_source":   ctx.new_pw_source,
        "reset_status":    ctx.reset_status,
        "db_update_status":ctx.db_update_status,
        "error_reason":    ctx.error_reason,
        "timestamp":       ctx.timestamp,
    }


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _cli():
    import argparse

    parser = argparse.ArgumentParser(
        prog="pw_utils.py",
        description="PAMS Password Utility CLI",
    )
    sub = parser.add_subparsers(dest="cmd")

    # gen-password
    sub.add_parser("gen-password", help="Generate a random PAMS-policy password")

    # fetch-password
    fp = sub.add_parser("fetch-password", help="Fetch stored password from PAMS DB")
    fp.add_argument("node_ip")
    fp.add_argument("username")

    # update-db
    ud = sub.add_parser("update-db", help="Update password in PAMS DB after successful reset")
    ud.add_argument("node_ip")
    ud.add_argument("username")
    ud.add_argument("new_password")

    # resolve
    rv = sub.add_parser("resolve", help="Show resolved old+new passwords for a node")
    rv.add_argument("node_ip")
    rv.add_argument("username")
    rv.add_argument("old_pw", nargs="?", default="")
    rv.add_argument("new_pw", nargs="?", default="")

    args = parser.parse_args()

    if args.cmd == "gen-password":
        pw = generate_password()
        print(pw)
        sys.exit(0)

    elif args.cmd == "fetch-password":
        try:
            pw = fetch_password_from_db(args.node_ip, args.username)
        except Exception as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(1)
        if pw is None:
            print("NOT_FOUND", file=sys.stderr)
            sys.exit(2)
        print(pw)
        sys.exit(0)

    elif args.cmd == "update-db":
        try:
            ok = update_db_after_reset(args.node_ip, args.username, args.new_password)
        except Exception as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(1)
        if not ok:
            print("NOT_FOUND", file=sys.stderr)
            sys.exit(2)
        print("UPDATED")
        sys.exit(0)

    elif args.cmd == "resolve":
        ctx = resolve_passwords_for_node(
            args.node_ip, args.username, args.old_pw, args.new_pw
        )
        print(json.dumps({
            "node_ip":      ctx.node_ip,
            "username":     ctx.username,
            "old_pw_source":ctx.old_pw_source,
            "old_password": ctx.old_password,
            "new_pw_source":ctx.new_pw_source,
            "new_password": ctx.new_password,
            "error_reason": ctx.error_reason,
            "reset_status": ctx.reset_status,
        }, indent=2))
        sys.exit(0 if not ctx.error_reason else 1)

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    _cli()

