import os
import csv as csv_mod
import subprocess
import threading
import logging

from django.shortcuts import render, redirect, get_object_or_404
from django.contrib.auth import authenticate, login, logout
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.http import FileResponse, JsonResponse, HttpResponse
from django.utils import timezone
from django.conf import settings
from django.core.mail import EmailMultiAlternatives
from django.views import View  # Added for Class-based view
from django.db import transaction # Added for atomic transactions
from django.contrib.auth.models import User # Added for User provisioning
from django.urls import reverse
from .access import user_can_card, user_reset_types

from .models import (
    TaskJob, NodePasswordExpiry, NodeType,
    ExpiryAlertConfig
)
from .ldap_login import Ldap # Assumes ldap_login.py is in the same folder
from . import forms # Assumes you have a forms.py with LoginForm
import csv
import json
from io import BytesIO, StringIO
from datetime import datetime, timedelta, date

from django.core.paginator import Paginator
from .forms import RegistrationForm  # add this import at top of file
# -------------------------------------------------------------
# Logger  (reads path from settings - media/logs/netops.log)
# -------------------------------------------------------------
logger = logging.getLogger('netops')

# -------------------------------------------------------------
# Helpers
# -------------------------------------------------------------

def _task_choices():
    """Returns list of (key, label) tuples from settings.TASK_CONFIG."""
    return [(k, v['label']) for k, v in settings.TASK_CONFIG.items()]


def _script_for(task_type):
    cfg = settings.TASK_CONFIG.get(task_type)
    if not cfg:
        return None
    return os.path.join(settings.BASH_SCRIPTS_DIR, cfg['script'])


def _output_log_dir(subfolder):
    """Returns media/logs/<subfolder>/ path, creating it if needed."""
    path = os.path.join(settings.MEDIA_ROOT, 'logs', subfolder)
    os.makedirs(path, exist_ok=True)
    return path


# -------------------------------------------------------------
# Background script runner
# -------------------------------------------------------------

def _run_script(job_id, script_path, input_path, output_path, target_script=None):
    logger.info("[Job #%s] Starting - script: %s", job_id, script_path)
    start_time = timezone.now()
    from pathlib import Path
    from .job_logging import get_job_logger
    _script_name = Path(target_script or script_path).stem
    job_logger, _job_log_dir = get_job_logger(job_id, _script_name)
    job_logger.info("Job %s starting - script=%s", job_id, script_path)

    job = None
    try:
        job = TaskJob.objects.get(pk=job_id)
        job.status = 'running'
        job.save()

        if not os.path.isfile(script_path):
            raise FileNotFoundError(f"Script not found: {script_path}")

        # 1. Build the command dynamically
        cmd = ['bash', script_path]
        if target_script:
            cmd.append(target_script) # Injects 'dns_password_reset.sh' if provided
        cmd.extend([input_path, output_path])

        # 2. Run the single, correct command
        '''result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=600
        )'''

        import signal
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            start_new_session=True,        # new process GROUP -> killpg works
            encoding='utf-8', errors='replace',
            env={**os.environ, 'JOB_LOG_DIR': str(_job_log_dir)},
        )
        job.process_pid = process.pid
        job.save(update_fields=['process_pid'])
        try:
            _stdout, _stderr = process.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
            _stdout, _stderr = process.communicate()
            raise
        # Re-check: a terminate request may have flipped status meanwhile
        job.refresh_from_db(fields=['status'])
        if job.status == 'terminated':
            logger.warning("[Job #%s] was terminated by staff.", job_id)
            return
        # Emulate the old `result` object the rest of the function expects:
        class _R: pass
        result = _R()
        result.returncode = process.returncode
        result.stdout = _stdout
        result.stderr = _stderr


        try:
            result.stdout = result.stdout.decode('utf-8', errors='replace')
        except AttributeError:
            pass  # already a string

        try:
            result.stderr = result.stderr.decode('utf-8', errors='replace')
        except AttributeError:
            pass  # already a string        

        if result.stdout:
            logger.info("[Job #%s] STDOUT:\n%s", job_id, result.stdout.strip())
        if result.stderr:
            logger.warning("[Job #%s] STDERR:\n%s", job_id, result.stderr.strip())

        if result.returncode == 0 and os.path.exists(output_path):
            rel = os.path.relpath(output_path, settings.MEDIA_ROOT)
            job.output_file   = rel
            job.status        = 'completed'
            job.error_message = ''
            logger.info("[Job #%s] Completed.", job_id)
        else:
            job.status = 'failed'
            parts = []
            if result.returncode != 0:
                parts.append(f"Exit code: {result.returncode}")
            if result.stderr.strip():
                parts.append(f"STDERR: {result.stderr.strip()}")
            if not os.path.exists(output_path):
                parts.append("Output file was not created.")
            job.error_message = '\n'.join(parts) or 'Script failed with no output.'
            logger.error("[Job #%s] Failed: %s", job_id, job.error_message)

    except FileNotFoundError as e:
        if job is None:
            job = TaskJob.objects.get(pk=job_id)
        job.status        = 'failed'
        job.error_message = str(e)
        logger.error("[Job #%s] FileNotFoundError: %s", job_id, e)

    except subprocess.TimeoutExpired:
        if job is None:
            job = TaskJob.objects.get(pk=job_id)
        job.status        = 'failed'
        job.error_message = 'Script timed out after 10 minutes.'
        logger.error("[Job #%s] Timeout.", job_id)

    except Exception as e:
        if job is None:
            job = TaskJob.objects.get(pk=job_id)
        job.status        = 'failed'
        job.error_message = f'{type(e).__name__}: {e}'
        logger.exception("[Job #%s] Unexpected: %s", job_id, e)

    finally:
        if job is not None:
            end_time             = timezone.now()
            job.completed_at     = end_time
            job.duration_seconds = int((end_time - start_time).total_seconds())
            job.save()
            
            # In _run_script() finally block, after job.save():
            try:
              if job.status == 'completed' and job.task_type in ('reset_password'):
                  from .pams_db_hook import post_reset_db_hook
                  post_reset_db_hook(job)
            except Exception as _hook_exc:
               logger.warning("[Job #%s] PAMS DB hook error (non-fatal): %s", job_id, _hook_exc)
            
            
            logger.info("[Job #%s] Final status: %s | duration: %ss",
                        job_id, job.status, job.duration_seconds)


def _submit_task(request, task_type):
    if task_type not in settings.TASK_CONFIG:
        messages.error(request, f'Unknown task type: {task_type}')
        return redirect('dashboard:dashboard')
        
    if not user_can_card(request.user, task_type):
        messages.error(request, 'Your role does not allow this task.')
        return redirect('dashboard:dashboard')

    if 'csv_file' not in request.FILES:
        messages.error(request, 'Please upload a CSV file.')
        return redirect('dashboard:dashboard')

    uploaded = request.FILES['csv_file']
    if not (uploaded.name.endswith('.csv') or uploaded.name.endswith('.xlsx')):
        messages.error(request, 'Only .csv and .xlsx files are allowed.')
        return redirect('dashboard:dashboard')

    job = TaskJob.objects.create(
        user=request.user,
        task_type=task_type,
        status='pending',
    )
    # Save upload as media/uploads/<jobid>_<original_filename>
    safe_name = os.path.basename(uploaded.name).replace(' ', '_')
    job.input_file.save(f'{job.pk}_{safe_name}', uploaded, save=True)
    logger.info("[Job #%s] Created by '%s' - task: %s, file: %s",
                job.pk, request.user.username, task_type, uploaded.name)

    input_abs  = os.path.join(settings.MEDIA_ROOT, job.input_file.name)
    output_dir = os.path.join(settings.MEDIA_ROOT, 'outputs')
    os.makedirs(output_dir, exist_ok=True)
    output_abs = os.path.join(output_dir, f'{task_type}_output_{job.pk}.csv')

    script_abs = _script_for(task_type)
    if not os.path.isfile(script_abs):
        job.status        = 'failed'
        job.error_message = f"Script not found: {script_abs}"
        job.completed_at  = timezone.now()
        job.save()
        messages.error(request, f'Script not found in bash_scripts/ folder.')
        return redirect('dashboard:dashboard')

    threading.Thread(
        target=_run_script,
        args=(job.pk, script_abs, input_abs, output_abs),
        daemon=True
    ).start()

    messages.success(request, f'Task submitted (Job #{job.pk}). Check status below.')
    return redirect('dashboard:dashboard')


# -------------------------------------------------------------
# Auth
# -------------------------------------------------------------

def login_view(request):
    if request.user.is_authenticated:
        return redirect('dashboard:dashboard')
    if request.method == 'POST':
        username = request.POST.get('username', '').strip()
        password = request.POST.get('password', '')
        user = authenticate(request, username=username, password=password)
        if user:
            logger.info("User '%s' logged in.", username)
            login(request, user)
            return redirect('dashboard:dashboard')
        else:
            logger.warning("Failed login attempt for: '%s'", username)
            messages.error(request, 'Invalid username or password.')
    return render(request, 'dashboard/login.html')


def logout_view(request):
    logger.info("User '%s' logged out.", request.user.username)
    logout(request)
    return redirect('dashboard:login')

# ================================================================
# PASTE THESE TWO FUNCTIONS into views.py replacing the existing
# dashboard() and download_sample() functions
# ================================================================

@login_required
def dashboard(request):
    if request.user.is_staff:
        recent_jobs = TaskJob.objects.all().order_by('-created_at')[:20]
    else:
        recent_jobs = TaskJob.objects.filter(user=request.user).order_by('-created_at')[:10]

    # Human-readable label map for ALL task types.
    # get_task_type_display() only works if the model choices match
    # exactly - this dict is the safe fallback used in the template.
    task_display_map = {
        'login_check':        'Login Check',
        'reachability_check': 'Reachability Check',
        'reset_password':     'Reset Password',
        'update_password':    'Update Password in DB',
    }
    # Also pull any labels defined in TASK_CONFIG (keeps it in sync)
    for k, v in settings.TASK_CONFIG.items():
        task_display_map.setdefault(k, v.get('label', k))
    for job in recent_jobs:
        job.display_name = task_display_map.get(job.task_type, job.task_type.replace('_', ' ').title())
    return render(request, 'dashboard/dashboard.html', {
        'recent_jobs':      recent_jobs,
        'task_choices':     _task_choices(),
        'task_display_map': task_display_map,
    })


@login_required
def download_sample(request, task_type):
    # -- reset_password is NOT in TASK_CONFIG (uses RESET_PASSWORD_SCRIPTS)
    #    so we handle it separately with a generic combined sample CSV --
    if task_type == 'reset_password':
        sample_name = 'sample_reset_password.csv'
        # Try serving from disk first (place this file in BASH_SCRIPTS_DIR
        # if you want a custom sample)
        file_path = os.path.join(str(settings.BASH_SCRIPTS_DIR), sample_name)
        if os.path.isfile(file_path):
            logger.info("Serving reset_password sample from disk: %s", file_path)
            response = FileResponse(open(file_path, 'rb'), as_attachment=True)
            response['Content-Disposition'] = f'attachment; filename="{sample_name}"'
            return response
        # Fallback: generate in-memory sample covering all three node types
        sample_content = (
            'NodeIP,NodeType,Username,OldPassword,NewPassword\n'
            '10.0.0.1,DNS,admin,OldPass@1,NewPass@2\n'
            '10.0.0.2,CMM,root,OldPass@3,NewPass@4\n'
            '10.0.0.3,WMG,espdtmb,OldPass@5,NewPass@6\n'
        )
        logger.info("Serving reset_password sample from memory")
        response = HttpResponse(sample_content, content_type='text/csv')
        response['Content-Disposition'] = f'attachment; filename="{sample_name}"'
        return response

    # -- All other task types are defined in TASK_CONFIG --
    cfg = settings.TASK_CONFIG.get(task_type)
    if not cfg:
        messages.error(request, 'Sample not found.')
        return redirect('dashboard:dashboard')

    file_path = os.path.join(str(settings.BASH_SCRIPTS_DIR), cfg['sample_file'])
    if os.path.isfile(file_path):
        logger.info("Serving sample CSV from disk: %s", file_path)
        response = FileResponse(open(file_path, 'rb'), as_attachment=True)
        response['Content-Disposition'] = 'attachment; filename="{}"'.format(cfg['sample_file'])
        return response

    logger.info("Serving sample CSV from memory (file not found): %s", file_path)
    response = HttpResponse(cfg['sample_content'], content_type='text/csv')
    response['Content-Disposition'] = 'attachment; filename="{}"'.format(cfg['sample_file'])
    return response

# -------------------------------------------------------------
# Individual task endpoints
# -------------------------------------------------------------

@login_required
def login_check(request):
    if request.method == 'POST':
        return _submit_task(request, 'login_check')
    return redirect('dashboard:dashboard')


@login_required
def reachability_check(request):
    if request.method == 'POST':
        return _submit_task(request, 'reachability_check')
    return redirect('dashboard:dashboard')


@login_required
def update_password(request):
    if request.method == 'POST':
        return _submit_task(request, 'update_password')
    return redirect('dashboard:dashboard')


@login_required
def reset_password(request):
    if request.method != 'POST':
        return redirect('dashboard:dashboard')
        
    if not user_can_card(request.user, 'reset_password'):
        messages.error(request, 'Your role does not allow this task.')
        return redirect('dashboard:dashboard')

    if 'csv_file' not in request.FILES:
        messages.error(request, 'Please upload a CSV file.')
        return redirect('dashboard:dashboard')

    uploaded = request.FILES['csv_file']
    if not (uploaded.name.endswith('.csv') or uploaded.name.endswith('.xlsx')):
        messages.error(request, 'Only .csv and .xlsx files are allowed.')
        return redirect('dashboard:dashboard')

    node_type   = request.POST.get('node_type', '').strip().lower()
    
    if node_type not in user_reset_types(request.user):
        messages.error(request, 'Your role cannot reset this node type.')
        return redirect('dashboard:dashboard')
        
    script_name = settings.RESET_PASSWORD_SCRIPTS.get(node_type)
    if not script_name:
        messages.error(request, 'Please select a valid node type (DNS or CMM).')
        return redirect('dashboard:dashboard')

    # script_abs = os.path.join(settings.BASH_SCRIPTS_DIR, script_name)
    wrapper    = os.path.join(settings.BASH_SCRIPTS_DIR, 'pw_reset_wrapper.sh')
    target_sh  = os.path.join(settings.BASH_SCRIPTS_DIR, script_name)
    script_abs = wrapper   # wrapper is the entry point


    job = TaskJob.objects.create(
        user=request.user,
        task_type='reset_password',
        input_file=uploaded,
        status='pending',
    )

    input_abs  = os.path.join(settings.MEDIA_ROOT, job.input_file.name)
    output_dir = os.path.join(settings.MEDIA_ROOT, 'outputs')
    os.makedirs(output_dir, exist_ok=True)
    output_abs = os.path.join(output_dir, f'reset_password_output_{job.pk}.csv')

    logger.info("[Job #%s] Reset Password - node_type='%s' script='%s' user='%s'",
                job.pk, node_type.upper(), script_name, request.user.username)

    if not os.path.isfile(script_abs):
        job.status        = 'failed'
        job.error_message = f"Script not found: {script_abs}"
        job.completed_at  = timezone.now()
        job.save()
        messages.error(request, f'Script "{script_name}" not found.')
        return redirect('dashboard:dashboard')

    threading.Thread(
            target=_run_script,
            # Notice we are passing `script_name` as the 5th argument here!
            args=(job.pk, script_abs, input_abs, output_abs, script_name),
            daemon=True
        ).start()

    label = node_type.upper()
    messages.success(request, f'Job #{job.pk} submitted - {label} ({uploaded.name})')
    return redirect('dashboard:dashboard')


# -------------------------------------------------------------
# Job status (AJAX) + download
# -------------------------------------------------------------

@login_required
def job_status(request, job_id):
    if request.user.is_staff:
        job = get_object_or_404(TaskJob, pk=job_id)
    else:
        job = get_object_or_404(TaskJob, pk=job_id, user=request.user)
    return JsonResponse({
        'status':           job.status,
        'error':            job.error_message,
        'duration_seconds': job.duration_seconds,
        'output_url':       request.build_absolute_uri('/media/' + job.output_file.name)
                            if job.output_file else None,
    })


@login_required
def download_output(request, job_id):
    if request.user.is_staff:
        job = get_object_or_404(TaskJob, pk=job_id)
    else:
        job = get_object_or_404(TaskJob, pk=job_id, user=request.user)
    if not job.output_file:
        messages.error(request, 'Output file not ready yet.')
        return redirect('dashboard:dashboard')
    file_path = os.path.join(str(settings.MEDIA_ROOT), job.output_file.name)
    fname = os.path.basename(file_path)
    response = FileResponse(open(file_path, 'rb'), as_attachment=True)
    response['Content-Disposition'] = 'attachment; filename="{}"'.format(fname)
    return response

@login_required
def terminate_job(request, job_id):
    """Staff-only: terminate a running job and its whole process group."""
    import os, signal
    if not request.user.is_staff:
        return JsonResponse({'ok': False, 'msg': 'Staff only'}, status=403)
    job = get_object_or_404(TaskJob, pk=job_id)
    if job.status != 'running' or not job.process_pid:
        return JsonResponse({'ok': False, 'msg': 'Job is not running'}, status=400)
    try:
        os.killpg(os.getpgid(job.process_pid), signal.SIGTERM)
    except ProcessLookupError:
        pass  # already gone - still mark terminated below
    job.status        = 'terminated'
    job.terminated_by = request.user
    job.terminated_at = timezone.now()
    job.completed_at  = timezone.now()
    job.error_message = f'Terminated by {request.user.username}'
    job.save()
    logger.warning("[Job #%s] terminated by '%s'", job.pk, request.user.username)
    return JsonResponse({'ok': True})


# -------------------------------------------------------------
# Log viewer (staff only) - reads from media/logs/netops.log
# -------------------------------------------------------------

@login_required
def view_logs(request):
    #          if not request.user.is_staff:
    if not user_can_flag(request.user, 'can_view_logs'):
        messages.error(request, 'Access denied. Staff only.')
        return redirect('dashboard:dashboard')

    log_file = os.path.join(settings.MEDIA_ROOT, 'logs', 'netops.log')
    log_content = ''
    if os.path.exists(log_file):
        with open(log_file, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
            log_content = ''.join(lines[-200:])
    else:
        log_content = 'Log file not found yet. Run a task first.'

    filter_job = request.GET.get('job_id', '').strip()
    if filter_job:
        filtered = [l for l in log_content.splitlines()
                    if f'[Job #{filter_job}]' in l]
        log_content = '\n'.join(filtered) or f'No entries for Job #{filter_job}'

    return render(request, 'dashboard/logs.html', {
        'log_content': log_content,
        'filter_job':  filter_job,
    })


# -------------------------------------------------------------
# Password Expiry - DB-backed (NodePasswordExpiry + NodeType)
# -------------------------------------------------------------

'''def _parse_date(raw):
    for fmt in ('%d-%m-%Y', '%Y-%m-%d', '%d/%m/%Y', '%m/%d/%Y'):
        try:
            return datetime.strptime(raw.strip(), fmt).date()
        except ValueError:
            continue
    return None'''

def _parse_date(raw):
    if not raw or not str(raw).strip():
        return None
    raw = str(raw).strip()

    for fmt in (
        '%d-%m-%Y',    # 23-04-2026
        '%Y-%m-%d',    # 2026-04-23
        '%d/%m/%Y',    # 23/04/2026
        '%m/%d/%Y',    # 04/23/2026
        '%d.%m.%Y',    # 23.04.2026
        '%Y/%m/%d',    # 2026/04/23
        # -- Excel short/long month name formats --------------
        '%d-%b-%y',    # 23-Apr-26   - THIS was missing (Excel default)
        '%d-%b-%Y',    # 23-Apr-2026
        '%d/%b/%Y',    # 23/Apr/2026
        '%d %b %Y',    # 23 Apr 2026
        '%d %B %Y',    # 23 April 2026
        '%b %d, %Y',   # Apr 23, 2026
        '%B %d, %Y',   # April 23, 2026
        '%d-%b-%y'.upper(),  # 23-APR-26 (allcaps from some Oracle exports)
    ):
        try:
            return datetime.strptime(raw, fmt).date()
        except ValueError:
            continue

    # Last attempt: try dateutil if available (handles almost anything)
    try:
        from dateutil import parser as du
        return du.parse(raw, dayfirst=True).date()
    except Exception:
        pass

    return None

def _compute_expiry(node):
    today       = date.today()
    policy_days = node.policy_days   # uses property -> NodeType.policy_days
    expiry_date = node.last_password_reset_date + timedelta(days=policy_days)
    days_left   = (expiry_date - today).days

    if days_left < 0:
        label  = f'Expired {abs(days_left)} days ago'
        status = 'expired'
    elif days_left == 0:
        label  = 'Expires Today'
        status = 'critical'
    elif days_left <= 7:
        label  = f'Expiry in {days_left} Days'
        status = 'warning'
    else:
        label  = f'Expiry in {days_left} Days'
        status = 'ok'

    return {
        'id':              node.pk,
        'managed_by':      node.managed_by,
        'username':        node.username,
        'node_name':       node.node_name,
        'node_ip':         node.node_ip,
        'node_type':       node.node_type.name if node.node_type else '',
        'policy_days':     policy_days,
        'expiry_date':     expiry_date.strftime('%d-%m-%Y'),
        'days_left':       days_left,
        'days_left_label': label,
        'node_owner':      node.node_owner,
        'recent_password': node.recent_password,
        'last_reset':      node.last_password_reset_date.strftime('%d-%m-%Y'),
        'status':          status,
        'is_active':       node.is_active,
        'updated_by':      node.updated_by.username if node.updated_by else '',
    }


# -- Shared filter helper for password-expiry table + Excel download --------
# Columns that support per-column text filtering (matches keys in the
# row dict returned by _compute_expiry()). Order doesn't matter here --
# the template controls display order; this is just the allow-list.
EXPIRY_FILTER_COLUMNS = [
    'managed_by', 'username', 'node_name', 'node_ip', 'node_type',
    'policy_days', 'last_reset', 'expiry_date', 'days_left_label',
    'node_owner', 'updated_by',
]


def _filter_expiry_rows(rows, q='', status='', column_filters=None):
    """
    Mirrors the client-side JS filter logic (global search box, status pill,
    and one text filter per column) so that "Download CSV" always exports
    exactly what the table's current filters would show.

    column_filters: dict like {'username': 'admin', 'node_type': 'dns'} --
    each value is matched as a case-insensitive substring against that
    row's corresponding field.
    """
    q              = (q or '').strip().lower()
    status         = (status or '').strip()
    column_filters = {
        k: v.strip().lower()
        for k, v in (column_filters or {}).items()
        if v and v.strip() and k in EXPIRY_FILTER_COLUMNS
    }

    out = []
    for r in rows:
        if status == 'danger' and r['status'] not in ('expired', 'critical'):
            continue
        if status == 'warning' and r['status'] != 'warning':
            continue
        if status == 'ok' and r['status'] != 'ok':
            continue

        if column_filters:
            skip = False
            for col, val in column_filters.items():
                if val not in str(r.get(col, '')).lower():
                    skip = True
                    break
            if skip:
                continue

        if q:
            haystack = ' '.join([
                r.get('managed_by', ''), r.get('username', ''),
                r.get('node_name', ''),  r.get('node_ip', ''),
                r.get('node_type', ''),  r.get('node_owner', ''),
                r.get('expiry_date', ''), r.get('last_reset', ''),
                r.get('updated_by', ''),
            ]).lower()
            if q not in haystack:
                continue

        out.append(r)
    return out


# -- CSV builder for password-expiry downloads -------------------------------
def _write_expiry_csv(rows, include_password=False):
    """
    Builds a CSV file (in-memory) for the given expiry rows.
    include_password=True adds the Recent Password column (admin-only use).
    Returns raw bytes (UTF-8 with BOM, so Excel opens it cleanly).
    """
    headers = ['Managed By', 'Username', 'Node Name', 'Node IP', 'Node Type',
               'Policy Days', 'Last Reset', 'Expiry Date', 'Days Left',
               'Node Owner']
    if include_password:
        headers.append('Recent Password')
    headers.append('Updated By')

    buf = StringIO()
    writer = csv.writer(buf)
    writer.writerow(headers)

    for r in rows:
        values = [
            r.get('managed_by', ''), r.get('username', ''),
            r.get('node_name', ''),  r.get('node_ip', ''),
            r.get('node_type', ''),  r.get('policy_days', ''),
            r.get('last_reset', ''), r.get('expiry_date', ''),
            r.get('days_left_label', ''), r.get('node_owner', ''),
        ]
        if include_password:
            values.append(r.get('recent_password', ''))
        values.append(r.get('updated_by', ''))
        writer.writerow(values)

    return ('\ufeff' + buf.getvalue()).encode('utf-8')


def _send_expiry_alertss(rows, alert_emails, threshold_days=7):
    expiring = [r for r in rows if 0 <= r['days_left'] <= threshold_days]
    if not expiring or not alert_emails:
        return 0

    table_rows = ''
    for r in expiring:
        table_rows += (
            '<tr><td>{managed_by}</td><td>{username}</td><td>{node_name}</td>'
            '<td>{node_ip}</td><td>{node_type}</td><td>{policy_days}</td>'
            '<td>{expiry_date}</td><td>{days_left_label}</td><td>{node_owner}</td></tr>'
        ).format(**r)

    html_body = """
    <h3 style="color:#c0392b;">Password Expiry Alert - Nodes Expiring Within {days} Days</h3>
    <table border="1" cellpadding="6" cellspacing="0"
           style="border-collapse:collapse;font-family:monospace;font-size:13px;">
      <thead style="background:#2c3e50;color:#fff;">
        <tr><th>Managed By</th><th>Username</th><th>Node Name</th>
        <th>Node IP</th><th>Node Type</th><th>Policy Days</th>
        <th>Expiry Date</th><th>Days Left</th><th>Node Owner</th></tr>
      </thead>
      <tbody>{rows}</tbody>
    </table>
    <p style="color:#7f8c8d;font-size:11px;">Automated alert - do not reply.</p>
    """.format(days=threshold_days, rows=table_rows)

    recipients = [e.strip() for e in alert_emails.splitlines() if e.strip()]
    try:
        subject = f'[PAMS] Password Expiry Alert - {len(expiring)} node(s) expiring within {threshold_days} days'
        msg = EmailMultiAlternatives(
            subject, 'See HTML version.',
            settings.DEFAULT_FROM_EMAIL, recipients
        )
        msg.attach_alternative(html_body, 'text/html')
        msg.send()
        logger.info("Expiry alert sent to %s - %s node(s)", recipients, len(expiring))
        return len(expiring)
    except Exception as e:
        logger.error("Failed to send expiry alert email: %s", e)
        return 0


def _read_csv_bytes(f):
    raw = f.read()
    # Try encodings in order: utf-8-sig (BOM), utf-8, latin-1/cp1252 (Windows)
    for enc in ('utf-8-sig', 'utf-8', 'cp1252', 'latin-1'):
        try:
            return raw.decode(enc).splitlines()
        except (UnicodeDecodeError, LookupError):
            continue
    # Last resort - decode with replacement chars
    return raw.decode('utf-8', errors='replace').splitlines()


# -- Staff config page -----------------------------------------

@login_required
def password_expiry_config(request):
    from .access import user_can_flag
    if not user_can_flag(request.user, 'can_edit_alert_config'):
    #if not request.user.is_staff:
        messages.error(request, 'Access denied')
        return redirect('dashboard:dashboard')

    config = ExpiryAlertConfig.get()

    if request.method == 'POST' and 'alert_days' in request.POST:
        config.alert_days   = int(request.POST.get('alert_days', 7))
        config.alert_emails = request.POST.get('alert_emails', '').strip()
        config.to_emails    = request.POST.get('to_emails', '').strip()
        config.cc_emails    = request.POST.get('cc_emails', '').strip()
        #config.bcc_emails   = request.POST.get('bcc_emails', '').strip()
        config.updated_by   = request.user
        config.save()
        logger.info("Expiry config saved by '%s'", request.user.username)
        messages.success(request, 'Configuration saved.')
        return redirect('dashboard:password_expiry_config')

    per_page = int(request.GET.get('per_page', 10))
    if per_page not in (10, 20, 50, 100):
        per_page = 10

    nodes    = NodePasswordExpiry.objects.filter(is_active=True).order_by('node_ip', 'username')
    all_rows = [_compute_expiry(n) for n in nodes]
    node_types = NodeType.objects.all().order_by('name')

    return render(request, 'dashboard/password_expiry.html', {
        'config':      config,
        'all_rows':    all_rows,
        'per_page':    per_page,
        'node_types':  node_types,
        'is_staff_view': True,
    })


# -- User-facing table -----------------------------------------

@login_required
def password_expiry_table(request):
    per_page = int(request.GET.get('per_page', 10))
    if per_page not in (10, 20, 50, 100):
        per_page = 10

    nodes      = NodePasswordExpiry.objects.filter(is_active=True).order_by('node_ip', 'username')
    all_rows   = [_compute_expiry(n) for n in nodes]
    node_types = NodeType.objects.all().order_by('name')

    return render(request, 'dashboard/password_expiry_table.html', {
        'all_rows':   all_rows,
        'per_page':   per_page,
        'node_types': node_types,
    })



# -- CSV download: Admin Config page (includes password column) -----------

@login_required
def download_expiry_csv_admin(request):
    from .access import user_can_flag
    if not user_can_flag(request.user, 'can_edit_alert_config'):
        messages.error(request, 'Access denied.')
        return redirect('dashboard:dashboard')

    nodes    = NodePasswordExpiry.objects.filter(is_active=True).order_by('node_ip', 'username')
    all_rows = [_compute_expiry(n) for n in nodes]

    column_filters = {col: request.GET.get('f_' + col, '') for col in EXPIRY_FILTER_COLUMNS}
    filtered = _filter_expiry_rows(
        all_rows,
        q=request.GET.get('q', ''),
        status=request.GET.get('status', ''),
        column_filters=column_filters,
    )

    csv_bytes = _write_expiry_csv(filtered, include_password=True)
    logger.info("Admin expiry CSV downloaded by '%s' - %s row(s)",
                request.user.username, len(filtered))

    filename = 'password_expiry_admin_{}.csv'.format(date.today().strftime('%Y%m%d'))
    response = HttpResponse(csv_bytes, content_type='text/csv')
    response['Content-Disposition'] = 'attachment; filename="{}"'.format(filename)
    return response


# -- CSV download: user-facing table (no password column) ------------------

@login_required
def download_expiry_csv_user(request):
    nodes    = NodePasswordExpiry.objects.filter(is_active=True).order_by('node_ip', 'username')
    all_rows = [_compute_expiry(n) for n in nodes]

    column_filters = {col: request.GET.get('f_' + col, '') for col in EXPIRY_FILTER_COLUMNS}
    filtered = _filter_expiry_rows(
        all_rows,
        q=request.GET.get('q', ''),
        status=request.GET.get('status', ''),
        column_filters=column_filters,
    )

    csv_bytes = _write_expiry_csv(filtered, include_password=False)
    logger.info("User expiry CSV downloaded by '%s' - %s row(s)",
                request.user.username, len(filtered))

    filename = 'password_expiry_{}.csv'.format(date.today().strftime('%Y%m%d'))
    response = HttpResponse(csv_bytes, content_type='text/csv')
    response['Content-Disposition'] = 'attachment; filename="{}"'.format(filename)
    return response


# -- Manual alert trigger --------------------------------------

@login_required
def run_expiry_check_now(request):
    from .access import user_can_flag
    if not user_can_flag(request.user, 'can_edit_alert_config'):
        messages.error(request, 'Access denied.')
        return redirect('dashboard:dashboard')

    if request.method == 'POST':
        config = ExpiryAlertConfig.get()
        nodes  = NodePasswordExpiry.objects.filter(is_active=True)
        rows   = [_compute_expiry(n) for n in nodes]

        if not rows:
            messages.error(request, 'No active node data in database. Import a CSV first.')
            return redirect('dashboard:password_expiry_config')

        from .expiry_email import send_escalated_alerts
        sent = send_escalated_alerts(rows, config=config)
        
        logger.info("Manual expiry check by '%s' - %s alert(s) sent.",
                    request.user.username, sent)
        messages.success(request, f'Expiry check done. Alert sent for {sent} node(s).')

    return redirect('dashboard:password_expiry_config')


# -- Full CSV upload (add new + update all columns) ------------

@login_required
def upload_expiry_csv(request):

    from .access import user_can_flag
    if not user_can_flag(request.user, 'can_edit_alert_config'):
        messages.error(request, 'Access denied.')
        return redirect('dashboard:dashboard')    

    if request.method != 'POST' or 'csv_file' not in request.FILES:
        messages.error(request, 'No file uploaded.')
        return redirect('dashboard:password_expiry_config')

    f = request.FILES['csv_file']
    if not f.name.lower().endswith('.csv'):
        messages.error(request, 'Only .csv files are supported.')
        return redirect('dashboard:password_expiry_config')

    reader  = csv.DictReader(_read_csv_bytes(f))
    created = updated = skipped = 0
    errors  = []

    for i, raw in enumerate(reader, start=2):
        row      = {k.strip(): (v.strip() if v else '') for k, v in raw.items()}
        node_ip  = row.get('Node IP', '').strip()
        username = row.get('Username', '').strip()

        if not node_ip or not username:
            errors.append(f'Row {i}: missing Node IP or Username - skipped.')
            skipped += 1
            continue

        reset_date = _parse_date(row.get('Last Password Reset Date', ''))
        if reset_date is None:
            errors.append(f'Row {i} ({node_ip}/{username}): unparseable date - skipped.')
            skipped += 1
            continue

        # Get or create NodeType from the string value in CSV
        # Use policy_days from CSV if provided, else default 90
        node_type_name = row.get('Node Type', '').strip()
        node_type_obj  = None
        if node_type_name:
            try:
                csv_policy_days = int(row.get('Policy Days', 90) or 90)
            except (ValueError, TypeError):
                csv_policy_days = 90

            node_type_obj, nt_created = NodeType.objects.get_or_create(
                name=node_type_name,
                defaults={'policy_days': csv_policy_days}
            )
            # If NodeType already existed but policy_days is different, update it
            if not nt_created and node_type_obj.policy_days != csv_policy_days:
                node_type_obj.policy_days = csv_policy_days
                node_type_obj.updated_by = request.user
                node_type_obj.save()

        _, created_flag = NodePasswordExpiry.objects.update_or_create(
            node_ip=node_ip,
            username=username,
            defaults={
                'managed_by':               row.get('Managed By', ''),
                'node_name':                row.get('Node Name', ''),
                'node_type':                node_type_obj,
                'node_owner':               row.get('Node Owner', ''),
                'last_password_reset_date': reset_date,
                'recent_password':          row.get('Recent Password', ''),
                'is_active':                True,
                'updated_by':               request.user,
            }
        )
        if created_flag:
            created += 1
        else:
            updated += 1

    summary = f'Full import done - {created} created, {updated} updated, {skipped} skipped.'
    logger.info("%s (by '%s')", summary, request.user.username)
    for e in errors[:5]:
        messages.warning(request, e)
    messages.success(request, summary)
    return redirect('dashboard:password_expiry_config')


# -- Partial update CSV (only date + password) -----------------

@login_required
def update_expiry_csv(request):
    from .access import user_can_flag
    if not user_can_flag(request.user, 'can_edit_alert_config'):
        messages.error(request, 'Access denied. Staff only.')
        return redirect('dashboard:dashboard')

    if request.method != 'POST' or 'update_csv_file' not in request.FILES:
        messages.error(request, 'No file uploaded.')
        return redirect('dashboard:password_expiry_config')

    f = request.FILES['update_csv_file']
    if not f.name.lower().endswith('.csv'):
        messages.error(request, 'Only .csv files are supported.')
        return redirect('dashboard:password_expiry_config')

    reader    = csv.DictReader(_read_csv_bytes(f))
    updated   = 0
    not_found = 0
    skipped   = 0
    errors    = []

    '''for i, raw in enumerate(reader, start=2):
        row      = {k.strip(): (v.strip() if v else '') for k, v in raw.items()}
        node_ip  = row.get('Node IP', '').strip()
        username = row.get('Username', '').strip()

        if not node_ip or not username:
            errors.append(f'Row {i}: missing Node IP or Username - skipped.')
            skipped += 1
            continue

        reset_date = _parse_date(row.get('Last Password Reset Date', ''))
        if reset_date is None:
            errors.append(f'Row {i} ({node_ip}/{username}): unparseable date - skipped.')
            skipped += 1
            continue'''
    
    for i, raw in enumerate(reader, start=2):
        # Normalize keys: lowercase + strip spaces so header casing doesn't matter
        # Accepts: "Node IP", "node_ip", "NODE IP", "node ip" etc.
        row = {
            k.strip().lower().replace(' ', '_'): (v.strip() if v else '')
            for k, v in raw.items() if k
        }

        # Accept both "node_ip" and "node ip" style headers
        node_ip  = (row.get('node_ip') or row.get('node ip') or '').strip()
        username = (row.get('username') or '').strip()

        if not node_ip or not username:
            errors.append(f'Row {i}: missing Node IP or Username - skipped.')
            skipped += 1
            continue

        # Accept "last_password_reset_date", "last password reset date", "Last Password Reset Date"
        date_raw = (
            row.get('last_password_reset_date') or
            row.get('last password reset date') or
            row.get('last_reset_date') or
            row.get('last_reset') or
            ''
        )
        reset_date = _parse_date(date_raw)
        if reset_date is None:
            errors.append(
                f'Row {i} ({node_ip}/{username}): '
                f'unparseable or missing date "{date_raw}" - skipped.'
            )
            skipped += 1
            continue

        # Accept "recent_password", "recent password", "password"
        pw_raw = (
            row.get('recent_password') or
            row.get('recent password') or
            row.get('password') or
            ''
        )

        count = NodePasswordExpiry.objects.filter(
            node_ip=node_ip, username=username
        ).update(
            last_password_reset_date=reset_date,
            #recent_password=row.get('Recent Password', '').strip(),
            recent_password=pw_raw,
            updated_by=request.user,
        )

        if count:
            updated += 1
        else:
            errors.append(f'Row {i} ({node_ip}/{username}): not found in DB - skipped.')
            not_found += 1

    summary = f'Update done - {updated} updated, {not_found} not found, {skipped} skipped.'
    logger.info("%s (by '%s')", summary, request.user.username)
    for e in errors[:5]:
        messages.warning(request, e)
    messages.success(request, summary)
    return redirect('dashboard:password_expiry_config')


# -- Bulk update NodeType policy / reset date ------------------

@login_required
def bulk_update_node_type(request):
    """
    Staff can update policy_days and/or default_last_reset_date for a NodeType.
    If default_last_reset_date is set, all nodes of that type get their
    last_password_reset_date updated to that date.
    """
    if not request.user.is_staff:
        messages.error(request, 'Access denied.')
        return redirect('dashboard:dashboard')

    if request.method != 'POST':
        return redirect('dashboard:password_expiry_config')

    node_type_id  = request.POST.get('node_type_id')
    policy_days   = request.POST.get('policy_days', '').strip()
    reset_date_raw = request.POST.get('default_last_reset_date', '').strip()

    try:
        nt = NodeType.objects.get(pk=node_type_id)
    except NodeType.DoesNotExist:
        messages.error(request, 'Node type not found.')
        return redirect('dashboard:password_expiry_config')

    if policy_days.isdigit():
        nt.policy_days = int(policy_days)

    reset_date = _parse_date(reset_date_raw) if reset_date_raw else None
    if reset_date:
        nt.default_last_reset_date = reset_date
        updated_count = NodePasswordExpiry.objects.filter(
            node_type=nt, is_active=True
        ).update(
            last_password_reset_date=reset_date,
            updated_by=request.user,
        )
        messages.success(request,
            f'Reset date updated for {updated_count} nodes of type "{nt.name}".')
        logger.info("Bulk reset date update: NodeType='%s' date='%s' by '%s' - %s nodes",
                    nt.name, reset_date, request.user.username, updated_count)

    nt.save()
    messages.success(request, f'NodeType "{nt.name}" saved.')
    return redirect('dashboard:password_expiry_config')


# -- Deactivate / reactivate node -----------------------------

@login_required
def toggle_node_active(request, node_id):
    if not request.user.is_staff:
        messages.error(request, 'Access denied.')
        return redirect('dashboard:dashboard')

    node = get_object_or_404(NodePasswordExpiry, pk=node_id)
    node.is_active = not node.is_active
    node.updated_by = request.user
    node.save()
    state = 'activated' if node.is_active else 'deactivated'
    messages.success(request, f'Node {node.node_ip}/{node.username} {state}.')
    logger.info("Node %s/%s %s by '%s'",
                node.node_ip, node.username, state, request.user.username)
    return redirect('dashboard:password_expiry_config')

def logout_view(request):
    """
    Standard Logout View
    """
    logger.info("User '%s' logged out.", request.user.username)
    logout(request)
    return redirect('dashboard:login')

class LoginUser(View):
    """
    Hybrid Login: Tries LDAP first, then falls back to Local Django DB.
    """
    message = ''
    error = False

    def format_data(self, ldap_data):
        """
        Formats raw LDAP results into a dictionary for User creation.
        """
        user_list = []
        for idx, ldap_obj in enumerate(ldap_data):
            for key, val in ldap_obj.items():
                username = val.get('cn')
                name = val.get('displayName')
                first_name = name.split(' ')[0] if name else None
                email = val.get('mail')
                last_name = val.get('sn')
                
                user_list.append({
                    'username': username, 
                    'last_name': last_name,
                    'email': email, 
                    'first_name': first_name,
                })
        return user_list

    def create_user_provisioning(self, data_list):
        """
        Handles automatic account creation for LDAP users.
        """
        data_list.reverse() # Maintain hierarchy sequence
        last_user = None
        for user in data_list:
            user_obj, created = User.objects.get_or_create(
                username=user.get('username'),
                defaults={
                    'email': user.get('email'),
                    'last_name': user.get('last_name'),
                    'first_name': user.get('first_name'),
                    'is_staff': True, # Grant access to NetOps dashboard
                    'is_active': True
                }
            )
            last_user = user_obj
        return last_user

    def get(self, request):
        if request.user.is_authenticated:
            return redirect('dashboard:dashboard')
        form = forms.LoginForm()
        return render(request, 'dashboard/login.html', {'form': form})

    @transaction.atomic
    def post(self, request):
        form = forms.LoginForm(request.POST)
        if form.is_valid():
            username = form.cleaned_data.get('username')
            password = form.cleaned_data.get('password')
            try:
                # MUST pass settings.LDAP_URL as the first argument
                ldap_obj = Ldap(
                    ldap_url=settings.LDAP_URL, 
                    username=username, 
                    password=password
                )
                
                ldap_data = ldap_obj.fetchdata(username)
                
                if len(ldap_data) >= 1:
                    data_list = self.format_data(ldap_data)
                    user_obj = self.create_user_and_userprofile_objects(data_list=data_list)
                    
                    login(request, user_obj)
                    return redirect('dashboard:dashboard')

            except Exception as e:
                logger.error("LDAP Auth Failed for '%s'. Error: %s", username, e)
                # Local database fallback
                user = authenticate(request, username=username, password=password)
                if user is not None:
                    login(request, user)
                    return redirect('dashboard:dashboard')
                
                messages.error(request, 'Invalid Credentials!')
                return redirect('dashboard:login')
            
        messages.error(request, 'Invalid Credentials! Login Failed.')
        return render(request, 'dashboard/login.html', {'form': form})

# -------------------------------------------------------------
# Self-Registration (account created as is_active=False)
# -------------------------------------------------------------

def register_view(request):
    """
    Public registration page.
    Creates account with is_active=False; admin must activate it.
    """
    if request.user.is_authenticated:
        return redirect('dashboard:dashboard')

    form = RegistrationForm()

    if request.method == 'POST':
        form = RegistrationForm(request.POST)
        if form.is_valid():
            from django.contrib.auth.models import User
            user = User.objects.create_user(
                username  = form.cleaned_data['username'],
                password  = form.cleaned_data['password1'],
                is_active = False,          # - account disabled until admin approves
            )
            logger.info(
                "New account registered (pending activation): '%s'",
                user.username
            )
            messages.success(
                request,
                'Account created! Please wait for an administrator to activate it '
                'before you can log in.'
            )
            return redirect('dashboard:login')

    return render(request, 'dashboard/register.html', {'form': form})    

# -- In-Memory CSV Generators for Password Expiry --

@login_required
def download_full_expiry_sample(request):
    """Generates a sample CSV for adding NEW nodes (Card 2)"""
    # Using columns exactly as required by upload_expiry_csv
    sample_content = (
        "Managed By,Username,Node Name,Node IP,Node Type,Node Owner,Last Password Reset Date,Policy Days,Recent Password\n"

    )
    response = HttpResponse(sample_content, content_type='text/csv')
    response['Content-Disposition'] = 'attachment; filename="sample_add_new_nodes.csv"'
    return response

@login_required
def download_partial_expiry_sample(request):
    """Generates a sample CSV for updating EXISTING nodes (Card 3)"""
    # Using 4 columns exactly as required by update_expiry_csv
    sample_content = (
        "Node IP,Username,Last Password Reset Date,Recent Password\n"
    )
    response = HttpResponse(sample_content, content_type='text/csv')
    response['Content-Disposition'] = 'attachment; filename="sample_update_nodes.csv"'
    return response
