"""
dashboard/log_explorer.py   (NEW FILE)
──────────────────────────────────────
Staff-only Admin Log Explorer — browses media/logs/ safely.

Security:
  * staff-only (is_staff check on every view)
  * path-traversal proof  (_safe() rejects anything resolving outside LOG_ROOT)
  * read-only  (no write/delete endpoints)

Wire-up (add to dashboard/urls.py, see instructions):
    path('log-explorer/',                 log_explorer.browse,   name='log_explorer'),
    path('log-explorer/view/',            log_explorer.view_file, name='log_explorer_view'),
    path('log-explorer/download/',        log_explorer.download,  name='log_explorer_download'),
"""
import os
from pathlib import Path
from django.conf import settings
from django.contrib.auth.decorators import login_required
from django.http import (
    Http404, HttpResponseForbidden, FileResponse, HttpResponse,
)
from django.shortcuts import render
from .access import user_can_flag


def _log_root():
    return (Path(settings.MEDIA_ROOT) / "logs").resolve()


def _safe(rel):
    """Resolve rel under LOG_ROOT; raise Http404 on traversal attempts."""
    root = _log_root()
    target = (root / (rel or "")).resolve()
    if target != root and root not in target.parents:
        raise Http404("Invalid path")
    return target


def _staff_or_403(request):
    from .access import user_can_flag
    if not user_can_flag(request.user, 'can_view_log_explorer'):
        return HttpResponseForbidden("Access denied.")
    return None



@login_required
def browse(request):
    block = _staff_or_403(request)
    if block:
        return block

    root = _log_root()
    root.mkdir(parents=True, exist_ok=True)
    rel = request.GET.get("path", "").strip("/")
    target = _safe(rel)

    if not target.exists():
        raise Http404("Not found")

    sort = request.GET.get("sort", "name")
    entries = []
    if target.is_dir():
        for p in target.iterdir():
            try:
                stat = p.stat()
            except OSError:
                continue
            entries.append({
                "name":   p.name,
                "is_dir": p.is_dir(),
                "size":   stat.st_size,
                "mtime":  stat.st_mtime,
                "rel":    os.path.relpath(p, root),
            })
        if sort == "date":
            entries.sort(key=lambda e: e["mtime"], reverse=True)
        elif sort == "size":
            entries.sort(key=lambda e: e["size"], reverse=True)
        else:
            entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))

    parent_rel = os.path.relpath(target.parent, root) if rel else ""
    return render(request, "dashboard/log_explorer.html", {
        "entries":    entries,
        "cur_rel":    rel,
        "parent_rel": "" if parent_rel == "." else parent_rel,
        "at_root":    (rel == ""),
        "sort":       sort,
    })


@login_required
def view_file(request):
    block = _staff_or_403(request)
    if block:
        return block

    rel = request.GET.get("path", "").strip("/")
    target = _safe(rel)
    if not target.is_file():
        raise Http404("Not a file")

    q = request.GET.get("q", "")
    try:
        text = target.read_text(encoding="utf-8", errors="replace")
    except OSError:
        raise Http404("Cannot read file")

    if q:
        text = "\n".join(l for l in text.splitlines() if q in l) or \
               f"(no lines matching '{q}')"

    # Pagination: show last N lines by default, full via ?full=1
    truncated = False
    if not request.GET.get("full"):
        lines = text.splitlines()
        if len(lines) > 1000:
            text = "\n".join(lines[-1000:])
            truncated = True

    return render(request, "dashboard/log_explorer_file.html", {
        "content":   text,
        "rel":       rel,
        "name":      target.name,
        "q":         q,
        "truncated": truncated,
        "parent_rel": os.path.relpath(target.parent, _log_root()),
    })


@login_required
def download(request):
    block = _staff_or_403(request)
    if block:
        return block

    rel = request.GET.get("path", "").strip("/")
    target = _safe(rel)
    if not target.is_file():
        raise Http404("Not a file")
    resp = FileResponse(open(target, "rb"), as_attachment=True)
    resp["Content-Disposition"] = f'attachment; filename="{target.name}"'
    return resp
