"""
dashboard/expiry_email.py
==========================
Escalation-aware expiry email sender with To/CC/BCC.

Behaviour:
  * Header/subject show the REAL minimum days-left (most urgent node),
    not a fixed threshold.
  * Every email ALWAYS includes a Node-Type summary table at the top
    (Node Type | Count Expiring | Most Urgent Username |
     Earliest Expiry (Days Left) | Earliest Expiry Date).
  * If the node count for that email is > 20, the detailed per-node
    table is NOT put in the body -- instead it is attached as an
    .xlsx file, and only the summary table appears in the body.
  * If the node count is <= 20, the full detailed table appears in
    the body (in addition to the summary table), same as before --
    no attachment.
  * Each active EscalationTier gets an email containing every node with
    days_left <= that tier's threshold (CUMULATIVE), addressed with the
    tier's own To / CC / BCC lists. This 20-node / attachment rule is
    evaluated PER TIER independently.
  * If NO tiers are configured, falls back to ExpiryAlertConfig, which
    also supports To/CC/BCC (config.to_list / cc_list / bcc_list). For
    backward-compat it also accepts the legacy single alert_emails list.

Usage from views.py:
    from .expiry_email import send_escalated_alerts
    sent = send_escalated_alerts(rows, config=config)
"""
import csv
from io import StringIO
from datetime import date

from django.conf import settings
from django.core.mail import EmailMultiAlternatives

import logging

logger = logging.getLogger('netops')

# Above this many nodes in a single email, switch from an inline HTML
# table to a .csv attachment (keeps the email body small/readable).
CSV_ATTACHMENT_THRESHOLD = 20


# -----------------------------------------------------------------
# Node-Type summary table (always shown, regardless of node count)
# -----------------------------------------------------------------

def _build_summary_table(nodes):
    """
    Groups `nodes` by node_type. For each type, reports the count and
    identifies the single most urgent node (lowest days_left) within
    that type, showing its username and expiry details.
    """
    groups = {}
    for r in nodes:
        nt = r.get('node_type') or '(unknown)'
        groups.setdefault(nt, []).append(r)

    summary_rows = []
    for nt, group in sorted(groups.items(), key=lambda kv: min(x['days_left'] for x in kv[1])):
        most_urgent = min(group, key=lambda x: x['days_left'])
        summary_rows.append({
            'node_type':        nt,
            'count':            len(group),
            'username':         most_urgent['username'],
            'days_left_label':  most_urgent['days_left_label'],
            'expiry_date':      most_urgent['expiry_date'],
        })

    rows_html = ''
    for s in summary_rows:
        rows_html += (
            '<tr>'
            '<td style="font-weight:600">{node_type}</td>'
            '<td style="text-align:center">{count}</td>'
            '<td>{username}</td>'
            '<td>{days_left_label}</td>'
            '<td>{expiry_date}</td>'
            '</tr>'
        ).format(**s)

    return """
    <h4 style="color:#1e1b4b;margin-bottom:6px;">Node Type Summary</h4>
    <table border="1" cellpadding="6" cellspacing="0"
           style="border-collapse:collapse;font-family:monospace;font-size:13px;margin-bottom:18px;">
      <thead style="background:#4f46e5;color:#fff;">
        <tr><th>Node Type</th><th>Count Expiring</th><th>Most Urgent Username</th>
        <th>Earliest Expiry (Days Left)</th><th>Earliest Expiry Date</th></tr>
      </thead>
      <tbody>{rows}</tbody>
    </table>
    """.format(rows=rows_html)


# -----------------------------------------------------------------
# Detailed per-node HTML table (only used when count <= threshold)
# -----------------------------------------------------------------

def _build_detail_table(nodes):
    rows_html = ''
    for r in nodes:
        rows_html += (
            '<tr><td>{managed_by}</td><td>{username}</td><td>{node_name}</td>'
            '<td>{node_ip}</td><td>{node_type}</td><td>{policy_days}</td>'
            '<td>{expiry_date}</td><td>{days_left_label}</td><td>{node_owner}</td></tr>'
        ).format(**r)

    return """
    <h4 style="color:#1e1b4b;margin-bottom:6px;">Node Details</h4>
    <table border="1" cellpadding="6" cellspacing="0"
           style="border-collapse:collapse;font-family:monospace;font-size:13px;">
      <thead style="background:#2c3e50;color:#fff;">
        <tr><th>Managed By</th><th>Username</th><th>Node Name</th>
        <th>Node IP</th><th>Node Type</th><th>Policy Days</th>
        <th>Expiry Date</th><th>Days Left</th><th>Node Owner</th></tr>
      </thead>
      <tbody>{rows}</tbody>
    </table>
    """.format(rows=rows_html)


def _build_html(title, nodes):
    """
    Full email body:
      - title
      - Node Type summary table (always)
      - Detailed table (only if node count <= CSV_ATTACHMENT_THRESHOLD)
      - Note about the attached Excel (only if count > threshold)
    """
    parts = ['<h3 style="color:#c0392b;">{}</h3>'.format(title)]
    parts.append(_build_summary_table(nodes))

    if len(nodes) > CSV_ATTACHMENT_THRESHOLD:
        parts.append(
            '<p style="color:#374151;font-size:13px;">'
            'Full list of {} expiring node(s) is attached as a CSV file '
            '(too many rows to show inline).</p>'.format(len(nodes))
        )
    else:
        parts.append(_build_detail_table(nodes))

    parts.append('<p style="color:#7f8c8d;font-size:11px;">Automated alert - do not reply.</p>')
    return ''.join(parts)


# -----------------------------------------------------------------
# Excel attachment builder (used only when count > threshold)
# -----------------------------------------------------------------

def _build_csv_attachment(nodes):
    """
    Builds a CSV file (in-memory bytes) listing all expiring nodes.
    Password is NOT included since this goes out over email.
    """
    headers = ['Managed By', 'Username', 'Node Name', 'Node IP', 'Node Type',
               'Policy Days', 'Last Reset', 'Expiry Date', 'Days Left', 'Node Owner']

    buf = StringIO()
    writer = csv.writer(buf)
    writer.writerow(headers)

    for r in nodes:
        writer.writerow([
            r.get('managed_by', ''), r.get('username', ''),
            r.get('node_name', ''),  r.get('node_ip', ''),
            r.get('node_type', ''),  r.get('policy_days', ''),
            r.get('last_reset', ''), r.get('expiry_date', ''),
            r.get('days_left_label', ''), r.get('node_owner', ''),
        ])

    return ('\ufeff' + buf.getvalue()).encode('utf-8')


# -----------------------------------------------------------------
# Sender
# -----------------------------------------------------------------

def _send(subject, html, to_list, cc_list=None, bcc_list=None, attachment=None):
    """
    attachment: optional tuple (filename, bytes, mimetype) -- when
    provided, gets attached to the email via EmailMultiAlternatives.attach().
    """
    to_list  = to_list  or []
    cc_list  = cc_list  or []
    bcc_list = bcc_list or []
    if not (to_list or cc_list or bcc_list):
        return False
    if not to_list:
        to_list = [settings.DEFAULT_FROM_EMAIL]
    try:
        msg = EmailMultiAlternatives(
            subject, 'See HTML version.',
            settings.DEFAULT_FROM_EMAIL,
            to=to_list, cc=cc_list, bcc=bcc_list,
        )
        msg.attach_alternative(html, 'text/html')
        if attachment:
            filename, content, mimetype = attachment
            msg.attach(filename, content, mimetype)
        msg.send()
        logger.info("Expiry alert sent - to=%s cc=%s bcc=%s attachment=%s",
                    to_list, cc_list, bcc_list, bool(attachment))
        return True
    except Exception as e:
        logger.error("Failed to send expiry alert: %s", e)
        return False


def _dispatch_one(title, subject, nodes, to_list, cc_list, bcc_list):
    """
    Builds body (+ Excel attachment if needed) and sends one email for
    the given node list. Shared by both the fallback branch and the
    per-tier branch below.
    """
    html = _build_html(title, nodes)

    attachment = None
    if len(nodes) > CSV_ATTACHMENT_THRESHOLD:
        csv_bytes = _build_csv_attachment(nodes)
        filename = 'expiring_nodes_{}.csv'.format(date.today().strftime('%Y%m%d'))
        attachment = (filename, csv_bytes, 'text/csv')

    return _send(subject, html, to_list, cc_list, bcc_list, attachment=attachment)


def send_escalated_alerts(rows, config=None):
    """
    rows:   list of node dicts (each has 'days_left', 'days_left_label',
            'node_type', 'username', etc).
    config: ExpiryAlertConfig instance (used for fallback + default days).
    Returns total number of node-emails dispatched.
    """
    from .models_rbac import EscalationTier

    tiers = list(EscalationTier.objects.filter(is_active=True).order_by('order'))

    # -- Backward-compatible fallback: no tiers configured --
    if not tiers:
        if config is None:
            return 0
        fallback_days = int(getattr(config, 'alert_days', 7) or 7)
        expiring = [r for r in rows if 0 <= r['days_left'] <= fallback_days]
        if not expiring:
            return 0

        to_list  = config.to_list()  if hasattr(config, 'to_list')  else []
        cc_list  = config.cc_list()  if hasattr(config, 'cc_list')  else []
        bcc_list = config.bcc_list() if hasattr(config, 'bcc_list') else []
        if not (to_list or cc_list or bcc_list):
            to_list = [e.strip() for e in (config.alert_emails or '').splitlines() if e.strip()]
        if not (to_list or cc_list or bcc_list):
            return 0

        min_days = min(r['days_left'] for r in expiring)
        title   = 'Password Expiry Alert - {} node(s), most urgent in {} day(s)'.format(
            len(expiring), min_days)
        subject = '[PAMS] Password Expiry Alert - {} node(s), min {} day(s) left'.format(
            len(expiring), min_days)

        return len(expiring) if _dispatch_one(
            title, subject, expiring, to_list, cc_list, bcc_list
        ) else 0

    # -- Escalation tiers (cumulative) --
    total_dispatched = 0
    for tier in tiers:
        tier_nodes = [r for r in rows if 0 <= r['days_left'] <= tier.days_threshold]
        if not tier_nodes or not tier.has_recipients():
            continue
        min_days = min(r['days_left'] for r in tier_nodes)
        title   = '[{label}] Password Expiry Alert - {n} node(s), most urgent in {d} day(s)'.format(
            label=tier.label, n=len(tier_nodes), d=min_days)
        subject = '[PAMS][{label}] {n} node(s) expiring, min {d} day(s) left'.format(
            label=tier.label, n=len(tier_nodes), d=min_days)

        if _dispatch_one(title, subject, tier_nodes,
                          tier.to_list(), tier.cc_list(), tier.bcc_list()):
            total_dispatched += len(tier_nodes)

    return total_dispatched
