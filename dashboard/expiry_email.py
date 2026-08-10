"""
dashboard/expiry_email.py   (NEW FILE)
======================================
Feature 3 — escalation-aware expiry email sender with To/CC/BCC.

Behaviour:
  * Header/subject show the REAL minimum days-left (most urgent node),
    not a fixed threshold.
  * Each active EscalationTier gets an email containing every node with
    days_left <= that tier's threshold (CUMULATIVE), addressed with the
    tier's own To / CC / BCC lists.
  * If NO tiers are configured, falls back to ExpiryAlertConfig, which now
    also supports To/CC/BCC (config.to_list / cc_list / bcc_list). For
    backward-compat it also accepts the legacy single alert_emails list.

Usage from views.py:
    from .expiry_email import send_escalated_alerts
    sent = send_escalated_alerts(rows, config=config)
"""
from django.conf import settings
from django.core.mail import EmailMultiAlternatives
import logging

logger = logging.getLogger('netops')


def _build_html(title, nodes):
    rows_html = ''
    for r in nodes:
        rows_html += (
            '<tr><td>{managed_by}</td><td>{username}</td><td>{node_name}</td>'
            '<td>{node_ip}</td><td>{node_type}</td><td>{policy_days}</td>'
            '<td>{expiry_date}</td><td>{days_left_label}</td><td>{node_owner}</td></tr>'
        ).format(**r)

    return """
    <h3 style="color:#c0392b;">{title}</h3>
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
    """.format(title=title, rows=rows_html)


def _send(subject, html, to_list, cc_list=None, bcc_list=None):
    to_list  = to_list  or []
    cc_list  = cc_list  or []
    bcc_list = bcc_list or []
    if not (to_list or cc_list or bcc_list):
        return False
    # EmailMultiAlternatives requires a non-empty `to`; if only CC/BCC given,
    # fall back to using the From address as the visible To.
    if not to_list:
        to_list = [settings.DEFAULT_FROM_EMAIL]
    try:
        msg = EmailMultiAlternatives(
            subject, 'See HTML version.',
            settings.DEFAULT_FROM_EMAIL,
            to=to_list, cc=cc_list, bcc=bcc_list,
        )
        msg.attach_alternative(html, 'text/html')
        msg.send()
        logger.info("Expiry alert sent — to=%s cc=%s bcc=%s", to_list, cc_list, bcc_list)
        return True
    except Exception as e:
        logger.error("Failed to send expiry alert: %s", e)
        return False


def send_escalated_alerts(rows, config=None):
    """
    rows:   list of node dicts (each has 'days_left' and 'days_left_label').
    config: ExpiryAlertConfig instance (used for fallback + default days).
    Returns total number of node-emails dispatched.
    """
    from .models_rbac import EscalationTier

    tiers = list(EscalationTier.objects.filter(is_active=True).order_by('order'))

    # ── Backward-compatible fallback: no tiers configured ──
    if not tiers:
        if config is None:
            return 0
        fallback_days = int(getattr(config, 'alert_days', 7) or 7)
        expiring = [r for r in rows if 0 <= r['days_left'] <= fallback_days]
        if not expiring:
            return 0

        # Prefer new To/CC/BCC on config; fall back to legacy alert_emails as To
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
        html = _build_html(title, expiring)
        return len(expiring) if _send(subject, html, to_list, cc_list, bcc_list) else 0

    # ── Escalation tiers (cumulative) ──
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
        html = _build_html(title, tier_nodes)
        if _send(subject, html, tier.to_list(), tier.cc_list(), tier.bcc_list()):
            total_dispatched += len(tier_nodes)

    return total_dispatched
