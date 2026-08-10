"""
pams_db_hook.py  –  Django-side PAMS DB Update Hook
======================================================
Placed in:  dashboard/pams_db_hook.py

Provides:
  post_reset_db_update(job_id)
    – Called after a reset_password or mme/wmg/dns/cmm task completes
    – Reads the job's output CSV
    – For each SUCCESS row, updates dashboard_nodepasswordexpiry
    – Logs results to the Django logger

This is a PLUG-IN style addition.
It does NOT modify views.py logic – it is called from a post-hook
registered in _run_script() via a one-line addition (see DIFF below).

DIFF for views.py (minimal, one block):
---------------------------------------
  # At the bottom of the _run_script() finally block, AFTER job.save():
  #
  from .pams_db_hook import post_reset_db_update
  if job.status == 'completed' and job.task_type in (
          'reset_password', 'mme_reset', 'dns_reset', 'wmg_reset', 'cmm_reset'):
      post_reset_db_hook(job)
"""

from __future__ import annotations

import csv
import logging
import datetime
import os
import sys
from pathlib import Path
from typing import Optional

logger = logging.getLogger("netops")

# Locate pw_utils (lives in bash_scripts/)
_HERE         = Path(__file__).resolve().parent          # dashboard/
_PROJECT_ROOT = _HERE.parent                              # pams_project_v3/
_BASH_DIR     = _PROJECT_ROOT / "bash_scripts"

if str(_BASH_DIR) not in sys.path:
    sys.path.insert(0, str(_BASH_DIR))

try:
    from pw_utils import update_db_after_reset, fetch_password_from_db, get_pams_logger
    _PW_UTILS_OK = True
except ImportError as _e:
    logger.error("pams_db_hook: cannot import pw_utils: %s", _e)
    _PW_UTILS_OK = False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def post_reset_db_hook(job) -> dict:
    """
    Called after a reset task job completes successfully.

    job: TaskJob model instance with job.output_file set.

    Returns summary dict:
      {
        "processed":  int,
        "db_updated": int,
        "db_failed":  int,
        "db_skipped": int,
      }
    """
    summary = {"processed": 0, "db_updated": 0, "db_failed": 0, "db_skipped": 0}

    if not _PW_UTILS_OK:
        logger.error("[Job #%s] pams_db_hook: pw_utils not available", job.pk)
        return summary

    if not job.output_file:
        logger.warning("[Job #%s] pams_db_hook: no output_file on job", job.pk)
        return summary

    from django.conf import settings
    output_path = Path(settings.MEDIA_ROOT) / job.output_file.name
    if not output_path.exists():
        logger.warning("[Job #%s] pams_db_hook: output file not found: %s", job.pk, output_path)
        return summary

    logger.info("[Job #%s] pams_db_hook: processing output CSV: %s", job.pk, output_path)

    # Read the wrapper-enhanced CSV (has DBUpdateStatus column) or raw CSV
    try:
        with open(output_path, newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            rows   = list(reader)
    except Exception as exc:
        logger.error("[Job #%s] pams_db_hook: cannot read CSV: %s", job.pk, exc)
        return summary

    for row in rows:
        summary["processed"] += 1
        r = {k.strip(): (v or "").strip() for k, v in row.items()}

        # Status column (varies by script)
        status   = r.get("Status") or r.get("status") or ""
        node_ip  = r.get("NodeIP") or r.get("node_ip") or r.get("IP") or ""
        username = r.get("Username") or r.get("username") or r.get("USER") or ""

        # If wrapper already handled the DB update, skip to avoid double-write
        db_status = r.get("DBUpdateStatus", "")
        if db_status in ("SUCCESS", "FAILED", "NOT_FOUND"):
            logger.debug(
                "[Job #%s] pams_db_hook: skip %s/%s – wrapper already handled (DBUpdateStatus=%s)",
                job.pk, node_ip, username, db_status,
            )
            summary["db_skipped"] += 1
            continue

        if status.upper() != "SUCCESS":
            summary["db_skipped"] += 1
            continue

        if not node_ip or not username:
            summary["db_skipped"] += 1
            continue

        # Try to determine new_password from the enriched CSV
        new_pw = r.get("NewPassword") or r.get("new_password") or ""

        if not new_pw:
            # Fallback: re-read from PAMS DB (won't be the new one yet, but
            # signals the node is tracked). Best effort – skip if blank.
            logger.warning(
                "[Job #%s] pams_db_hook: no new_password for %s/%s – skipping DB update",
                job.pk, node_ip, username,
            )
            summary["db_skipped"] += 1
            continue

        # Perform DB update
        try:
            ok = update_db_after_reset(node_ip, username, new_pw)
            if ok:
                logger.info(
                    "[Job #%s] pams_db_hook: DB updated ip=%s user=%s",
                    job.pk, node_ip, username,
                )
                summary["db_updated"] += 1
            else:
                logger.warning(
                    "[Job #%s] pams_db_hook: ip=%s user=%s not in PAMS DB",
                    job.pk, node_ip, username,
                )
                summary["db_skipped"] += 1
        except Exception as exc:
            logger.error(
                "[Job #%s] pams_db_hook: DB update failed ip=%s user=%s: %s",
                job.pk, node_ip, username, exc,
            )
            summary["db_failed"] += 1

    logger.info(
        "[Job #%s] pams_db_hook summary: processed=%d updated=%d failed=%d skipped=%d",
        job.pk, summary["processed"], summary["db_updated"],
        summary["db_failed"], summary["db_skipped"],
    )
    return summary
