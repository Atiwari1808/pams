"""
dashboard/admin_rbac.py   (NEW VERSION — Group-based)
=====================================================
Attaches PAMS settings to Django's Group admin (so "Roles" = Groups), and
registers EscalationTier. Import at bottom of admin.py:
    from . import admin_rbac   # noqa

Result:
  * Group admin (renamed "Roles") gains a GroupProfile inline with checkboxes
    for cards / reset types / page flags.
  * Assigning roles to a user = the standard Groups dual-list on the User page.
  * EscalationTier admin shows To/CC/BCC boxes.
"""
from django import forms
from django.contrib import admin
from django.contrib.auth.admin import GroupAdmin
from django.contrib.auth.models import Group

from .models_rbac import (
    GroupProfile, EscalationTier,
    CARD_CHOICES, RESET_TYPE_CHOICES,
)


# ─────────────────────────────────────────────────────────────
# GroupProfile inline on the Group admin
# ─────────────────────────────────────────────────────────────

class GroupProfileForm(forms.ModelForm):
    allowed_cards = forms.MultipleChoiceField(
        choices=CARD_CHOICES, required=False,
        widget=forms.CheckboxSelectMultiple,
        help_text='Cards this role can see and use on the dashboard.'
    )
    allowed_reset_types = forms.MultipleChoiceField(
        choices=RESET_TYPE_CHOICES, required=False,
        widget=forms.CheckboxSelectMultiple,
        help_text='Reset-password node types this role may run.'
    )

    class Meta:
        model = GroupProfile
        fields = '__all__'

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if self.instance and self.instance.pk:
            self.fields['allowed_cards'].initial = self.instance.card_list()
            self.fields['allowed_reset_types'].initial = self.instance.reset_type_list()

    def clean_allowed_cards(self):
        return ','.join(self.cleaned_data.get('allowed_cards', []))

    def clean_allowed_reset_types(self):
        return ','.join(self.cleaned_data.get('allowed_reset_types', []))


class GroupProfileInline(admin.StackedInline):
    model = GroupProfile
    form = GroupProfileForm
    can_delete = False
    verbose_name = 'PAMS access settings'
    verbose_name_plural = 'PAMS access settings'
    fieldsets = (
        ('Dashboard cards', {'fields': ('allowed_cards', 'allowed_reset_types')}),
        ('Page / button access', {
            'fields': ('can_view_password_expiry', 'can_edit_alert_config',
                       'can_view_logs', 'can_view_log_explorer', 'can_access_admin'),
        }),
    )


class RoleGroupAdmin(GroupAdmin):
    """Standard Group admin + the PAMS settings inline."""
    inlines = [GroupProfileInline]


# Re-register Group as "Roles" with the inline
admin.site.unregister(Group)
admin.site.register(Group, RoleGroupAdmin)

# Optional: relabel the Group model to "Role" in the admin sidebar
Group._meta.verbose_name = 'Role'
Group._meta.verbose_name_plural = 'Roles'


# ─────────────────────────────────────────────────────────────
# EscalationTier admin (To / CC / BCC)
# ─────────────────────────────────────────────────────────────

@admin.register(EscalationTier)
class EscalationTierAdmin(admin.ModelAdmin):
    list_display  = ('order', 'label', 'days_threshold',
                     'to_count', 'cc_count', 'bcc_count', 'is_active')
    list_editable = ('label', 'days_threshold', 'is_active')
    ordering      = ('order',)
    fieldsets = (
        (None, {'fields': ('order', 'label', 'days_threshold', 'is_active')}),
        ('Recipients', {
            'fields': ('to_emails', 'cc_emails', 'bcc_emails'),
            'description': 'One email per line in each box. '
                           'To = primary, CC = visible copy, BCC = hidden copy.',
        }),
    )

    def to_count(self, obj):  return len(obj.to_list())
    def cc_count(self, obj):  return len(obj.cc_list())
    def bcc_count(self, obj): return len(obj.bcc_list())
    to_count.short_description  = 'To'
    cc_count.short_description  = 'CC'
    bcc_count.short_description = 'BCC'
