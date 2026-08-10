"""
Management command: check_password_expiry
=========================================
Reads node data from NodePasswordExpiry (active nodes only).
Sends alerts using the SAME escalation-aware sender as the web UI, so cron
and the dashboard behave identically:
  * real remaining-days header (not a fixed threshold)
  * To / CC / BCC support
  * cumulative escalation tiers when configured
  * falls back to ExpiryAlertConfig (To/CC/BCC, then legacy alert_emails)

Run via cron:
    0 8 * * * /path/to/venv/bin/python /path/to/manage.py check_password_expiry
"""
import logging
from datetime import date, timedelta

from django.core.management.base import BaseCommand

from dashboard.models import NodePasswordExpiry, ExpiryAlertConfig

logger = logging.getLogger('netops')


def _compute_rows():
    today = date.today()
    rows  = []
    for node in NodePasswordExpiry.objects.filter(is_active=True).select_related('node_type'):
        policy_days = node.policy_days
        expiry_date = node.last_password_reset_date + timedelta(days=policy_days)
        days_left   = (expiry_date - today).days

        if days_left < 0:
            label = f'Expired {abs(days_left)} days ago'
        elif days_left == 0:
            label = 'Expires Today'
        else:
            label = f'Expiry in {days_left} Days'

        rows.append({
            'managed_by':      node.managed_by,
            'username':        node.username,
            'node_name':       node.node_name,
            'node_ip':         node.node_ip,
            'node_type':       node.node_type.name if node.node_type else '',
            'policy_days':     policy_days,
            'last_reset':      node.last_password_reset_date.strftime('%d-%m-%Y'),
            'expiry_date':     expiry_date.strftime('%d-%m-%Y'),
            'days_left':       days_left,
            'days_left_label': label,
            'node_owner':      node.node_owner,
        })
    return rows


class Command(BaseCommand):
    help = 'Check password expiry from DB and send alert emails (escalation + To/CC/BCC).'

    def handle(self, *args, **kwargs):
        from dashboard.expiry_email import send_escalated_alerts
        from dashboard.models_rbac import EscalationTier

        self.stdout.write('=' * 60)
        self.stdout.write('[ExpiryCheck] Starting password expiry check (DB mode)...')

        config = ExpiryAlertConfig.get()

        # Show what recipients are visible across BOTH systems (for the log)
        tiers = list(EscalationTier.objects.filter(is_active=True).order_by('order'))
        if tiers:
            self.stdout.write(f'[ExpiryCheck] Escalation tiers active : {len(tiers)}')
            for t in tiers:
                self.stdout.write(
                    f"   - Tier {t.order} '{t.label}' (<= {t.days_threshold}d): "
                    f"To={len(t.to_list())} CC={len(t.cc_list())} BCC={len(t.bcc_list())}"
                )
        else:
            to  = config.to_list()  if hasattr(config, 'to_list')  else []
            cc  = config.cc_list()  if hasattr(config, 'cc_list')  else []
            bcc = config.bcc_list() if hasattr(config, 'bcc_list') else []
            self.stdout.write(f'[ExpiryCheck] No tiers — using config '
                              f'To={len(to)} CC={len(cc)} BCC={len(bcc)} '
                              f'(legacy alert_days={config.alert_days})')

        all_nodes = _compute_rows()
        self.stdout.write(f'[ExpiryCheck] Active nodes in DB : {len(all_nodes)}')
        if not all_nodes:
            self.stdout.write(self.style.WARNING('[ExpiryCheck] No active nodes found.'))
            return

        # Delegate everything (filtering by days, tiers, To/CC/BCC) to the
        # shared sender so cron == web behaviour.
        sent = send_escalated_alerts(all_nodes, config=config)

        self.stdout.write('=' * 60)
        if sent:
            self.stdout.write(self.style.SUCCESS(
                f'Done. Alert dispatched for {sent} node-email(s).'))
        else:
            self.stdout.write(self.style.WARNING(
                'Done. Nothing sent (no nodes within threshold, or no recipients configured).'))
