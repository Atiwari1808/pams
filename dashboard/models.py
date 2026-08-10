from django.db import models
from django.contrib.auth.models import User
import os


# -------------------------------------------------------------
# NodeType � shared policy per node type
# -------------------------------------------------------------

class NodeType(models.Model):
    name = models.CharField(max_length=100, unique=True)
    policy_days = models.PositiveIntegerField(default=90)
    default_last_reset_date = models.DateField(
        null=True, blank=True,
        help_text='Bulk-set last reset date for all nodes of this type'
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    updated_by = models.ForeignKey(
        User, on_delete=models.SET_NULL,
        null=True, blank=True,
        related_name='nodetype_updates'
    )

    class Meta:
        ordering = ["name"]
        verbose_name = "Node type"
        verbose_name_plural = "Node types"

    def __str__(self):
        return "{} ({} days)".format(self.name, self.policy_days)


# -------------------------------------------------------------
# TaskJob � tracks every task run
# -------------------------------------------------------------

class TaskJob(models.Model):
    STATUS_CHOICES = [
        ('pending',   'Pending'),
        ('running',   'Running'),
        ('completed', 'Completed'),
        ('failed',    'Failed'),
        ('terminated', 'Terminated'),
    ]

    user         = models.ForeignKey(User, on_delete=models.CASCADE, related_name='jobs')
    task_type    = models.CharField(max_length=100)
    status       = models.CharField(max_length=20, choices=STATUS_CHOICES, default='pending')
    input_file   = models.FileField(upload_to='uploads/')
    output_file  = models.FileField(upload_to='outputs/', null=True, blank=True)
    error_message = models.TextField(blank=True)
    retry_count  = models.IntegerField(default=0)
    duration_seconds = models.IntegerField(null=True, blank=True)
    created_at   = models.DateTimeField(auto_now_add=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    process_pid   = models.IntegerField(null=True, blank=True)
    terminated_at = models.DateTimeField(null=True, blank=True)
    terminated_by = models.ForeignKey(
        User, null=True, blank=True,
        on_delete=models.SET_NULL, related_name='terminated_jobs'
    )


    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.user.username} - {self.task_type} - {self.status}"
    @property
    def task_type_display(self):
        """Returns a human-readable label for the task_type."""
        mapping = {
            'login_check': 'Login Check',
            'reachability_check': 'Reachability Check',
            'reset_password': 'Reset Password',
            'update_password': 'Update Password in DB',
        }
        # Returns the mapped value, or formats the string if not found
        return mapping.get(self.task_type, self.task_type.replace('_', ' ').title())

# -------------------------------------------------------------
# NodePasswordExpiry � per-node password expiry inventory
# -------------------------------------------------------------

class NodePasswordExpiry(models.Model):
    managed_by   = models.CharField(max_length=200, blank=True)
    username     = models.CharField(max_length=200)
    node_name    = models.CharField(max_length=200, blank=True)
    node_ip      = models.GenericIPAddressField(protocol='both', unpack_ipv4=True)
    node_type    = models.ForeignKey(
        NodeType,
        on_delete=models.PROTECT,
        null=True, blank=True,
        related_name='nodes'
    )
    node_owner             = models.CharField(max_length=200, blank=True)
    last_password_reset_date = models.DateField()
    recent_password        = models.CharField(max_length=500, blank=True)
    is_active              = models.BooleanField(default=True)

    created_at  = models.DateTimeField(auto_now_add=True)
    updated_at  = models.DateTimeField(auto_now=True)
    updated_by  = models.ForeignKey(
        User, on_delete=models.SET_NULL,
        null=True, blank=True,
        related_name='expiry_updates'
    )

    class Meta:
        unique_together = ('node_ip', 'username')
        ordering = ['node_ip', 'username']
        verbose_name = 'Node password expiry'
        verbose_name_plural = 'Node password expiries'

    def __str__(self):
        return f"{self.node_ip} / {self.username}"

    @property
    def policy_days(self):
        if self.node_type:
            return self.node_type.policy_days
        return 90


# -------------------------------------------------------------
# ExpiryAlertConfig � singleton, replaces expiry_config.json
# -------------------------------------------------------------

class ExpiryAlertConfig(models.Model):
    alert_days   = models.PositiveIntegerField(default=7)
    alert_emails = models.TextField(
        blank=True,
        help_text='(Legacy) one email per line. Used as To if To box is empty.'
    )
    # -- NEW: separate To / CC / BCC --
    to_emails    = models.TextField(blank=True, help_text='Primary recipients (To), one per line.')
    cc_emails    = models.TextField(blank=True, help_text='CC, one per line.')
    bcc_emails   = models.TextField(blank=True, help_text='BCC, one per line.')
 
    updated_at = models.DateTimeField(auto_now=True)
    updated_by = models.ForeignKey(
        User, on_delete=models.SET_NULL,
        null=True, blank=True
    )
 
    class Meta:
        verbose_name = 'Expiry alert config'
 
    @classmethod
    def get(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj
 
    # -- NEW helper methods --
    def to_list(self):
        items = [e.strip() for e in (self.to_emails or '').splitlines() if e.strip()]
        # If To is empty, fall back to the legacy alert_emails list
        if not items:
            items = [e.strip() for e in (self.alert_emails or '').splitlines() if e.strip()]
        return items
 
    def cc_list(self):
        return [e.strip() for e in (self.cc_emails or '').splitlines() if e.strip()]
 
    def bcc_list(self):
        return [e.strip() for e in (self.bcc_emails or '').splitlines() if e.strip()]
 
    def __str__(self):
        return f"Expiry alert config (alert {self.alert_days} days before)"


# -------------------------------------------------------------
# Legacy models kept for backward compat (not actively used)
# -------------------------------------------------------------

class PasswordExpiryConfig(models.Model):
    excel_file         = models.FileField(upload_to='password_expiry/', blank=True)
    alert_days_before  = models.CharField(max_length=50, default='7')
    alert_emails       = models.TextField(blank=True)
    last_updated       = models.DateTimeField(auto_now=True)
    updated_by         = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)

    def __str__(self):
        return f"Password Expiry Config (updated {self.last_updated.date()})"


class PasswordExpiryAlert(models.Model):
    device          = models.CharField(max_length=200)
    username        = models.CharField(max_length=200)
    expiry_date     = models.DateField()
    days_remaining  = models.IntegerField()
    alert_sent_at   = models.DateTimeField(auto_now_add=True)
    email_sent_to   = models.TextField()

    def __str__(self):
        return f"{self.device}/{self.username} - expires {self.expiry_date}"

from .models_rbac import GroupProfile, EscalationTier