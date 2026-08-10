"""
dashboard/job_logging.py   (NEW FILE)
─────────────────────────────────────
Centralized per-job logging utility.

Creates this structure automatically:

    media/logs/<jobid>_<scriptname>/
        ├── log_YYYYMMDD_HHMMSS.log   (everything, DEBUG+)
        ├── output.log               (INFO+)
        └── error.log                (ERROR+)

Usage:
    from dashboard.job_logging import get_job_logger
    job_logger, log_dir = get_job_logger(job_id, 'login_check')
    job_logger.info("started")

Concurrency-safe: handlers are attached once per unique logger name, so
parallel jobs (each with a unique job_id) get isolated handler sets.
No hardcoded paths — everything derives from settings.MEDIA_ROOT.
"""
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime
from pathlib import Path
from django.conf import settings


def get_job_logger(job_id, script_name):
    """Return (logger, log_dir_Path) for this job/script."""
    safe_script = "".join(
        ch for ch in str(script_name) if ch.isalnum() or ch in ("_", "-")
    ) or "task"

    log_dir = Path(settings.MEDIA_ROOT) / "logs" / f"{job_id}_{safe_script}"
    log_dir.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger(f"job.{job_id}.{safe_script}")
    logger.setLevel(logging.DEBUG)
    logger.propagate = False

    # Attach handlers only once (prevents duplicate lines on re-entry)
    if not logger.handlers:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        fmt = logging.Formatter(
            "%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S"
        )

        main_h = RotatingFileHandler(
            log_dir / f"log_{ts}.log",
            maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8",
        )
        main_h.setLevel(logging.DEBUG)
        main_h.setFormatter(fmt)
        logger.addHandler(main_h)

        out_h = RotatingFileHandler(
            log_dir / "output.log",
            maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8",
        )
        out_h.setLevel(logging.INFO)
        out_h.setFormatter(fmt)
        logger.addHandler(out_h)

        err_h = RotatingFileHandler(
            log_dir / "error.log",
            maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8",
        )
        err_h.setLevel(logging.ERROR)
        err_h.setFormatter(fmt)
        logger.addHandler(err_h)

    return logger, log_dir
