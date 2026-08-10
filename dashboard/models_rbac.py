"""
dashboard/models_rbac.py   (NEW VERSION — Group-based)
======================================================
Roles are now Django's built-in Group. We attach a GroupProfile (one-to-one)
to each Group to store PAMS-specific access (cards, reset types, page flags).

  GroupProfile   — Feature 1: per-group PAMS access settings
  EscalationTier — Feature 3: email escalation matrix with To/CC/BCC

REMOVED: Role, UserRoleProfile  (replaced by Group + GroupProfile)

Activate: at bottom of dashboard/models.py add:
    from .models_rbac import GroupProfile, EscalationTier   # noqa

Then:  python manage.py makemigrations && python manage.py migrate
"""
from django.db import models
from django.contrib.auth.models import Group


# ─────────────────────────────────────────────────────────────
# FEATURE 1 — Group-based access (GroupProfile attached to Group)
# ─────────────────────────────────────────────────────────────

CARD_CHOICES = [
    ('login_check',        'Login Check card'),
    ('reachability_check', 'Reachability Check card'),
    ('reset_password',     'Reset Password card'),
    ('update_password',    'Update Password in DB card'),
]

RESET_TYPE_CHOICES = [
    ('dns',        'DNS'),
    ('cmm',        'CMM'),
    ('wmg',        'WMG'),
    ('mme',        'SGSN/MME'),
    ('huawei_oss', 'Huawei OSS'),
    ('pcg', 'PCG'),
    ('pccsm', 'PCCSM')
]


class GroupProfile(models.Model):
    """
    PAMS access settings attached to a standard Django Group.
    A user's effective access = UNION across all their groups.
    Superusers (and staff if STAFF_BYPASS) bypass all checks.
    """
    group = models.OneToOneField(
        Group, on_delete=models.CASCADE, related_name='pams_profile'
    )

    allowed_cards = models.CharField(
        max_length=255, blank=True,
        help_text='Comma-separated card keys this role can access '
                  '(login_check,reachability_check,reset_password,update_password).'
    )
    allowed_reset_types = models.CharField(
        max_length=255, blank=True,
        help_text='Comma-separated reset node types (dns,cmm,wmg,mme,huawei_oss,pcg,pccsm).'
    )

    can_view_password_expiry = models.BooleanField(
        default=False, help_text='See the Password Expiry status page.')
    can_edit_alert_config = models.BooleanField(
        default=False, help_text='Edit Alert Configuration (days, To/CC/BCC, '
                                 'CSV import, send-now).')
    can_view_logs         = models.BooleanField(default=False)
    can_view_log_explorer = models.BooleanField(default=False)
    can_access_admin      = models.BooleanField(default=False)

    class Meta:
        verbose_name = 'Role settings (group profile)'
        verbose_name_plural = 'Role settings (group profiles)'

    def __str__(self):
        return f'PAMS settings for {self.group.name}'

    def card_list(self):
        return [c.strip() for c in self.allowed_cards.split(',') if c.strip()]

    def reset_type_list(self):
        return [c.strip() for c in self.allowed_reset_types.split(',') if c.strip()]


# ─────────────────────────────────────────────────────────────
# FEATURE 3 — Email Escalation Matrix with To / CC / BCC
# (unchanged from the To/CC/BCC version)
# ─────────────────────────────────────────────────────────────

def _split_emails(text):
    return [e.strip() for e in (text or '').splitlines() if e.strip()]


class EscalationTier(models.Model):
    """One escalation level with separate To / CC / BCC lists. Cumulative:
    a node with days_left <= a tier's threshold is included for that tier."""
    order          = models.PositiveIntegerField(default=1, help_text='1 = first/widest tier')
    label          = models.CharField(max_length=100, help_text='e.g. Team, Manager')
    days_threshold = models.PositiveIntegerField(
        help_text='Send to this tier when a node has this many days left or fewer.'
    )

    to_emails  = models.TextField(blank=True, help_text='Primary recipients (To), one per line.')
    cc_emails  = models.TextField(blank=True, help_text='CC, one per line.')
    bcc_emails = models.TextField(blank=True, help_text='BCC, one per line.')

    is_active  = models.BooleanField(default=True)

    class Meta:
        ordering = ['order']
        verbose_name = 'Escalation tier'
        verbose_name_plural = 'Escalation tiers (email matrix)'

    def __str__(self):
        return f'Tier {self.order}: {self.label} (<= {self.days_threshold} days)'

    def to_list(self):  return _split_emails(self.to_emails)
    def cc_list(self):  return _split_emails(self.cc_emails)
    def bcc_list(self): return _split_emails(self.bcc_emails)

    def has_recipients(self):
        return bool(self.to_list() or self.cc_list() or self.bcc_list())
