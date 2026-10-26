from django.contrib import admin
from django.utils.html import format_html
from django.contrib import messages
from django.shortcuts import render, redirect
from django.urls import path
from django.http import HttpResponseRedirect
from datetime import date, timedelta
from django import forms
from django.http import HttpResponse
import csv
from io import StringIO
import logging

from .models import (
    TaskJob, NodeType, NodePasswordExpiry,
    ExpiryAlertConfig
)

# -------------------------------------------------------------
# Audit logger
# -------------------------------------------------------------
audit_logger = logging.getLogger('netops')


def audit(user, model, action, detail=''):
    audit_logger.info(
        '[AUDIT] user=%-20s | model=%-30s | action=%-30s | %s',
        user, model, action, detail
    )


# -------------------------------------------------------------
# NodeType - custom ModelForm with bulk action fields
# -------------------------------------------------------------


class NodeTypeAdminForm(forms.ModelForm):
    bulk_password = forms.CharField(
        required=False, label='Bulk Password Update',
        widget=forms.TextInput(attrs={'placeholder': 'Leave blank to skip', 'autocomplete': 'off'}),
        help_text='Updates recent_password for matching nodes of this type.'
    )
    bulk_reset_date = forms.DateField(
        required=False, label='Bulk Reset Date',
        widget=forms.DateInput(attrs={'type': 'date'}),
        help_text='Updates last_password_reset_date for matching nodes.'
    )
    bulk_target_username = forms.ChoiceField(
        required=False, label='Apply to username',
        help_text='Leave on "All usernames" to affect every node of this type, '
                  'or pick one username to affect only that user\'s nodes.'
    )
 
    class Meta:
        model = NodeType
        fields = ('name', 'policy_days',)
 
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Build the username dropdown from this node type's existing nodes
        choices = [('', '-All usernames-')]
        if self.instance and self.instance.pk:
            usernames = (NodePasswordExpiry.objects
                         .filter(node_type=self.instance, is_active=True)
                         .values_list('username', flat=True)
                         .distinct().order_by('username'))
            choices += [(u, u) for u in usernames]
        self.fields['bulk_target_username'].choices = choices
 

# -------------------------------------------------------------
# NodePasswordExpiry inline - shown inside NodeType change page
# -------------------------------------------------------------

class NodePasswordExpiryInline(admin.TabularInline):

    model            = NodePasswordExpiry
    extra            = 0
    can_delete       = False
    show_change_link = True
    fields           = (
        'node_ip', 'username', 'node_name', 'node_owner',
        'last_password_reset_date', 'recent_password', 'is_active',
    )
    readonly_fields  = ('node_ip', 'username', 'node_name')
    ordering         = ('node_ip',)

    def get_queryset(self, request):
        # Only active nodes - keeps the page fast on large inventories
        return super().get_queryset(request).filter(is_active=True).select_related('node_type')


# -------------------------------------------------------------
# NodeType Admin
# -------------------------------------------------------------

@admin.register(NodeType)
class NodeTypeAdmin(admin.ModelAdmin):
    form          = NodeTypeAdminForm
    #inlines       = [NodePasswordExpiryInline]

    list_display  = ('name', 'policy_days',
                     'node_count', 'updated_at', 'updated_by_display')
    search_fields = ('name',)
    ordering      = ('name',)

    # updated_by is readonly - shown for info, never edited manually
    readonly_fields = ('updated_by',)

    fieldsets = (
        ('Node Type Settings', {
            'fields': ('name', 'policy_days', 'updated_by'),
        }),
        ('Bulk Actions', {
            'fields': ('bulk_target_username', 'bulk_password', 'bulk_reset_date'),
            'description': (
                'Fill only the field you want to update. '
                'Leave blank to skip. Changes apply to ALL active nodes of this type on SAVE.'
            ),
        }),
    )

    actions = [
        'bulk_reset_date_to_today',
        'bulk_reset_date_to_custom',
        'bulk_reset_date_to_default',
        'bulk_update_password',
    ]

    # -- URL registration for custom bulk views --------------
    def get_urls(self):
        urls = super().get_urls()
        custom = [
            path(
                'bulk-reset-custom/',
                self.admin_site.admin_view(self.bulk_reset_custom_view),
                name='nodetype_bulk_reset_custom',
            ),
            path(
                'bulk-update-password/',
                self.admin_site.admin_view(self.bulk_update_password_view),
                name='nodetype_bulk_update_password',
            ),
        ]
        return custom + urls

    # -- List display helpers ---------------------------------
    def node_count(self, obj):
        count = obj.nodes.filter(is_active=True).count()
        return format_html('<b>{}</b> active nodes', count)
    node_count.short_description = 'Active Nodes'

    def updated_by_display(self, obj):
        return obj.updated_by.username if obj.updated_by else '-'
    updated_by_display.short_description = 'Updated By'

    # -- save_model: handle bulk fields + auto-set updated_by -
    def save_model(self, request, obj, form, change):
        obj.updated_by = request.user
        super().save_model(request, obj, form, change)



        # Apply bulk password update
        bulk_password   = form.cleaned_data.get('bulk_password', '').strip()
        bulk_reset_date = form.cleaned_data.get('bulk_reset_date')
        target_user     = form.cleaned_data.get('bulk_target_username', '').strip()

        # Base queryset - all active nodes of this type, OR just one user's
        base_qs = NodePasswordExpiry.objects.filter(node_type=obj, is_active=True)
        if target_user:
            base_qs = base_qs.filter(username=target_user)

        scope = f"username='{target_user}'" if target_user else "ALL usernames"
        action_parts = []

        # Apply bulk password update
        if bulk_password:
            updated = base_qs.update(recent_password=bulk_password)
            self.message_user(
                request,
                '{} node(s) recent_password updated for type "{}" ({}).'.format(
                    updated, obj.name, scope),
                messages.SUCCESS)
            audit(request.user.username, 'NodeType:{}'.format(obj.name),
                  'bulk_password_update_inline',
                  'updated recent_password for {} nodes ({})'.format(updated, scope))
            action_parts.append('password_updated={}'.format(updated))

        # Apply bulk reset date
        if bulk_reset_date:
            updated = base_qs.update(last_password_reset_date=bulk_reset_date)
            self.message_user(
                request,
                '{} node(s) last_password_reset_date set to {} for type "{}" ({}).'.format(
                    updated, bulk_reset_date.strftime('%d-%m-%Y'), obj.name, scope),
                messages.SUCCESS)
            audit(request.user.username, 'NodeType:{}'.format(obj.name),
                  'bulk_reset_date_inline',
                  'set last_password_reset_date={} for {} nodes ({})'.format(
                      bulk_reset_date.strftime('%d-%m-%Y'), updated, scope))
            action_parts.append('date_updated={}'.format(updated))

        action = 'changed' if change else 'added'
        changed_fields = list(form.changed_data) if change else ['(new record)']
        audit(
            request.user.username,
            'NodeType:{}'.format(obj.name),
            action,
            'fields={} policy_days={} default_last_reset_date={} {}'.format(
                changed_fields, obj.policy_days, obj.default_last_reset_date,
                ' '.join(action_parts))
        )

    # -- Actions (list-level) ---------------------------------

    def bulk_reset_date_to_today(self, request, queryset):
        today = date.today()
        total = 0
        for nt in queryset:
            updated = NodePasswordExpiry.objects.filter(
                node_type=nt, is_active=True
            ).update(last_password_reset_date=today)
            nt.default_last_reset_date = today
            nt.updated_by = request.user
            nt.save()
            total += updated
            audit(request.user.username, 'NodeType:{}'.format(nt.name),
                  'bulk_reset_date_to_today',
                  'set last_password_reset_date={} for {} nodes'.format(
                      today.strftime('%d-%m-%Y'), updated))
        self.message_user(
            request,
            '{} node(s) last_password_reset_date set to today ({}).'.format(
                total, today.strftime('%d-%m-%Y')),
            messages.SUCCESS)
    bulk_reset_date_to_today.short_description = \
        'Set last reset date = TODAY for all nodes of selected type(s)'

    def bulk_reset_date_to_custom(self, request, queryset):
        selected = queryset.values_list('pk', flat=True)
        ids = ','.join(str(pk) for pk in selected)
        return HttpResponseRedirect(
            'bulk-reset-custom/?ids={}&action=reset_date'.format(ids)
        )
    bulk_reset_date_to_custom.short_description = \
        'Set last reset date = CUSTOM DATE for all nodes of selected type(s)'

    def bulk_reset_custom_view(self, request):
        ids_raw = request.GET.get('ids', '') or request.POST.get('ids', '')
        ids = [int(i) for i in ids_raw.split(',') if i.strip().isdigit()]
        queryset = NodeType.objects.filter(pk__in=ids)

        if request.method == 'POST' and 'apply' in request.POST:
            date_str = request.POST.get('reset_date', '').strip()
            try:
                from datetime import datetime
                reset_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            except ValueError:
                self.message_user(
                    request, 'Invalid date format. Use YYYY-MM-DD.', messages.ERROR)
                return redirect(request.path + '?ids=' + ids_raw)

            total = 0
            for nt in queryset:
                updated = NodePasswordExpiry.objects.filter(
                    node_type=nt, is_active=True
                ).update(last_password_reset_date=reset_date)
                nt.default_last_reset_date = reset_date
                nt.updated_by = request.user
                nt.save()
                total += updated
                audit(request.user.username, 'NodeType:{}'.format(nt.name),
                      'bulk_reset_date_to_custom',
                      'set last_password_reset_date={} for {} nodes'.format(
                          reset_date.strftime('%d-%m-%Y'), updated))
            self.message_user(
                request,
                '{} node(s) last_password_reset_date set to {}.'.format(
                    total, reset_date.strftime('%d-%m-%Y')),
                messages.SUCCESS)
            return redirect('../../')

        context = {
            'title':    'Set Custom Reset Date',
            'queryset': queryset,
            'ids':      ids_raw,
            'opts':     self.model._meta,
            'today':    date.today().strftime('%Y-%m-%d'),
        }
        return render(request, 'admin/nodetype_bulk_reset_custom.html', context)

    def bulk_reset_date_to_default(self, request, queryset):
        total = 0
        skipped = 0
        for nt in queryset:
            if not nt.default_last_reset_date:
                skipped += 1
                continue
            updated = NodePasswordExpiry.objects.filter(
                node_type=nt, is_active=True
            ).update(last_password_reset_date=nt.default_last_reset_date)
            total += updated
            audit(request.user.username, 'NodeType:{}'.format(nt.name),
                  'bulk_reset_date_to_default',
                  'set last_password_reset_date={} for {} nodes'.format(
                      nt.default_last_reset_date.strftime('%d-%m-%Y'), updated))
        msg = '{} node(s) updated.'.format(total)
        if skipped:
            msg += ' {} type(s) skipped (no default date set).'.format(skipped)
        self.message_user(request, msg, messages.SUCCESS)
    bulk_reset_date_to_default.short_description = \
        'Set last reset date = default_last_reset_date for all nodes of selected type(s)'

    def bulk_update_password(self, request, queryset):
        selected = queryset.values_list('pk', flat=True)
        ids = ','.join(str(pk) for pk in selected)
        return HttpResponseRedirect(
            'bulk-update-password/?ids={}'.format(ids)
        )
    bulk_update_password.short_description = \
        'Set recent_password for all nodes of selected type(s)'

    def bulk_update_password_view(self, request):
        ids_raw = request.GET.get('ids', '') or request.POST.get('ids', '')
        ids = [int(i) for i in ids_raw.split(',') if i.strip().isdigit()]
        queryset = NodeType.objects.filter(pk__in=ids)

        if request.method == 'POST' and 'apply' in request.POST:
            new_password = request.POST.get('new_password', '').strip()
            if not new_password:
                self.message_user(request, 'Password cannot be empty.', messages.ERROR)
                return redirect(request.path + '?ids=' + ids_raw)

            total = 0
            for nt in queryset:
                updated = NodePasswordExpiry.objects.filter(
                    node_type=nt, is_active=True
                ).update(recent_password=new_password)
                total += updated
                audit(request.user.username, 'NodeType:{}'.format(nt.name),
                      'bulk_update_password',
                      'updated recent_password for {} nodes'.format(updated))
            self.message_user(
                request,
                '{} node(s) recent_password updated.'.format(total),
                messages.SUCCESS)
            return redirect('../../')

        context = {
            'title':    'Bulk Update Password',
            'queryset': queryset,
            'ids':      ids_raw,
            'opts':     self.model._meta,
        }
        return render(request, 'admin/nodetype_bulk_update_password.html', context)

    def delete_model(self, request, obj):
        audit(request.user.username, 'NodeType:{}'.format(obj.name),
              'deleted',
              'policy_days={} node_count={}'.format(obj.policy_days, obj.nodes.count()))
        super().delete_model(request, obj)

    def delete_queryset(self, request, queryset):
        for obj in queryset:
            audit(request.user.username, 'NodeType:{}'.format(obj.name),
                  'bulk_deleted', 'policy_days={}'.format(obj.policy_days))
        super().delete_queryset(request, queryset)


# -------------------------------------------------------------
# NodePasswordExpiry Admin
# -------------------------------------------------------------

class ExpiryStatusFilter(admin.SimpleListFilter):
    title          = 'Expiry status'
    parameter_name = 'expiry_status'

    def lookups(self, request, model_admin):
        return [
            ('expired',  'Expired'),
            ('critical', 'Expires Today'),
            ('warning',  'Expiring within 7 days'),
            ('ok',       'OK (> 7 days)'),
        ]

    def queryset(self, request, queryset):
        if not self.value():
            return queryset
        today = date.today()
        ids = []
        for node in queryset.select_related('node_type'):
            policy = node.node_type.policy_days if node.node_type else 90
            expiry = node.last_password_reset_date + timedelta(days=policy)
            left   = (expiry - today).days
            if self.value() == 'expired'  and left < 0:      ids.append(node.pk)
            if self.value() == 'critical' and left == 0:     ids.append(node.pk)
            if self.value() == 'warning'  and 0 < left <= 7: ids.append(node.pk)
            if self.value() == 'ok'       and left > 7:      ids.append(node.pk)
        return queryset.filter(pk__in=ids)


@admin.register(NodePasswordExpiry)
class NodePasswordExpiryAdmin(admin.ModelAdmin):
    list_display   = ('node_ip', 'username', 'node_name', 'node_type_name',
                      'is_active', 'last_password_reset_date',
                      'expiry_date_col', 'days_left_col',
                      'updated_at', 'updated_by_display')
    list_filter    = ('is_active', 'node_type', ExpiryStatusFilter)
    search_fields  = ('node_ip', 'username', 'node_name', 'node_owner')
    readonly_fields = ('created_at', 'updated_at',
                       'expiry_date_display', 'days_left_display', 'updated_by')
    ordering       = ('node_ip', 'username')
    list_per_page  = 25
    #actions        = ['activate_nodes', 'deactivate_nodes', 'reset_date_to_today']
    actions = ['activate_nodes', 'deactivate_nodes', 'reset_date_to_today', 'bulk_set_custom_date', 'bulk_set_password', 'export_selected_to_csv']

    def get_fieldsets(self, request, obj=None):
        base = (
            ('Node Info', {
                'fields': ('node_ip', 'node_name', 'username', 'node_type',
                           'node_owner', 'managed_by', 'is_active')
            }),
            ('Password Info', {
                'fields': ('last_password_reset_date', 'recent_password',
                           'expiry_date_display', 'days_left_display')
            }),
        )
        if obj is not None:
            base += (
                ('Audit', {
                    'fields': ('updated_by', 'created_at', 'updated_at'),
                    'classes': ('collapse',)
                }),
            )
        return base

    def get_readonly_fields(self, request, obj=None):
        if obj is None:
            return ('expiry_date_display', 'days_left_display')
        return ('created_at', 'updated_at',
                'expiry_date_display', 'days_left_display', 'updated_by')

    def expiry_date_col(self, obj):
        if not obj.last_password_reset_date: return '-'
        policy = obj.node_type.policy_days if obj.node_type else 90
        return (obj.last_password_reset_date + timedelta(days=policy)).strftime('%d-%m-%Y')
    expiry_date_col.short_description = 'Expiry Date'

    def days_left_col(self, obj):
        if not obj.last_password_reset_date:
            return format_html('<span style="color:gray;">-</span>')
        today  = date.today()
        policy = obj.node_type.policy_days if obj.node_type else 90
        left   = (obj.last_password_reset_date + timedelta(days=policy) - today).days
        if left < 0:
            return format_html('<span style="color:red;font-weight:bold;">Exp {} days ago</span>', abs(left))
        elif left == 0:
            return format_html('<span style="color:red;font-weight:bold;">Today</span>')
        elif left <= 7:
            return format_html('<span style="color:orange;font-weight:bold;">{} days</span>', left)
        return format_html('<span style="color:green;">{} days</span>', left)
    days_left_col.short_description = 'Days Left'

    def node_type_name(self, obj):
        if obj.node_type:
            return '{} ({} days)'.format(obj.node_type.name, obj.node_type.policy_days)
        return '-'
    node_type_name.short_description = 'Node Type'

    def updated_by_display(self, obj):
        return obj.updated_by.username if obj.updated_by else '-'
    updated_by_display.short_description = 'Updated By'

    def expiry_date_display(self, obj):
        if not obj.last_password_reset_date: return '-'
        policy = obj.node_type.policy_days if obj.node_type else 90
        return (obj.last_password_reset_date + timedelta(days=policy)).strftime('%d-%m-%Y')
    expiry_date_display.short_description = 'Expiry Date'

    def days_left_display(self, obj):
        if not obj.last_password_reset_date: return '-'
        today  = date.today()
        policy = obj.node_type.policy_days if obj.node_type else 90
        left   = (obj.last_password_reset_date + timedelta(days=policy) - today).days
        if left < 0:
            return format_html('<span style="color:red;font-weight:bold;">Expired {} days ago</span>', abs(left))
        elif left == 0:
            return format_html('<span style="color:red;font-weight:bold;">Expires Today</span>')
        elif left <= 7:
            return format_html('<span style="color:orange;font-weight:bold;">{} days left</span>', left)
        return format_html('<span style="color:green;">{} days left</span>', left)
    days_left_display.short_description = 'Days Left'

    def activate_nodes(self, request, queryset):
        updated = queryset.update(is_active=True, updated_by=request.user)
        audit(request.user.username, 'NodePasswordExpiry', 'bulk_activate',
              'activated {} node(s)'.format(updated))
        self.message_user(request, '{} node(s) activated.'.format(updated), messages.SUCCESS)
    activate_nodes.short_description = 'Activate selected nodes'

    def deactivate_nodes(self, request, queryset):
        updated = queryset.update(is_active=False, updated_by=request.user)
        audit(request.user.username, 'NodePasswordExpiry', 'bulk_deactivate',
              'deactivated {} node(s)'.format(updated))
        self.message_user(request, '{} node(s) deactivated.'.format(updated), messages.WARNING)
    deactivate_nodes.short_description = 'Deactivate selected nodes'

    def reset_date_to_today(self, request, queryset):
        today   = date.today()
        updated = queryset.update(last_password_reset_date=today, updated_by=request.user)
        audit(request.user.username, 'NodePasswordExpiry', 'bulk_reset_date_today',
              'set last_password_reset_date={} for {} node(s)'.format(
                  today.strftime('%d-%m-%Y'), updated))
        self.message_user(request,
            '{} node(s) last reset date set to today ({}).'.format(
                updated, today.strftime('%d-%m-%Y')), messages.SUCCESS)
    reset_date_to_today.short_description = 'Set last reset date = TODAY for selected nodes'

    def export_selected_to_csv(self, request, queryset):
        """
        Exports the selected nodes (after any list_filter / search_fields
        narrowing already applied on the changelist) to a .csv file.
        Includes the Recent Password column since this is an
        administrator-only page.
        """
        headers = ['Managed By', 'Username', 'Node Name', 'Node IP', 'Node Type',
                   'Policy Days', 'Last Reset', 'Expiry Date', 'Days Left',
                   'Node Owner', 'Recent Password', 'Updated By']

        buf = StringIO()
        writer = csv.writer(buf)
        writer.writerow(headers)

        today = date.today()
        count = 0
        for node in queryset.select_related('node_type', 'updated_by').order_by('node_ip', 'username'):
            policy = node.node_type.policy_days if node.node_type else 90
            expiry = node.last_password_reset_date + timedelta(days=policy) if node.last_password_reset_date else None
            days_left = (expiry - today).days if expiry else ''
            if expiry:
                if days_left < 0:
                    days_left_label = 'Expired {} days ago'.format(abs(days_left))
                elif days_left == 0:
                    days_left_label = 'Expires Today'
                else:
                    days_left_label = 'Expiry in {} Days'.format(days_left)
            else:
                days_left_label = '-'

            writer.writerow([
                node.managed_by, node.username, node.node_name, node.node_ip,
                node.node_type.name if node.node_type else '',
                policy,
                node.last_password_reset_date.strftime('%d-%m-%Y') if node.last_password_reset_date else '',
                expiry.strftime('%d-%m-%Y') if expiry else '',
                days_left_label,
                node.node_owner,
                node.recent_password,
                node.updated_by.username if node.updated_by else '',
            ])
            count += 1

        audit(request.user.username, 'NodePasswordExpiry', 'export_csv',
              'exported {} node(s) to CSV'.format(count))

        filename = 'password_expiry_admin_{}.csv'.format(today.strftime('%Y%m%d'))
        csv_bytes = ('\ufeff' + buf.getvalue()).encode('utf-8')
        response = HttpResponse(csv_bytes, content_type='text/csv')
        response['Content-Disposition'] = 'attachment; filename="{}"'.format(filename)
        return response
    export_selected_to_csv.short_description = 'Export selected nodes to CSV (with password)'

    def save_model(self, request, obj, form, change):
        obj.updated_by = request.user
        super().save_model(request, obj, form, change)
        action = 'changed' if change else 'added'
        changed_fields = list(form.changed_data) if change else ['(new record)']
        audit(request.user.username,
              'NodePasswordExpiry:{}/{}'.format(obj.node_ip, obj.username),
              action, 'fields={}'.format(changed_fields))

    def delete_model(self, request, obj):
        audit(request.user.username,
              'NodePasswordExpiry:{}/{}'.format(obj.node_ip, obj.username),
              'deleted',
              'node_type={} is_active={}'.format(
                  obj.node_type.name if obj.node_type else 'None', obj.is_active))
        super().delete_model(request, obj)

    def delete_queryset(self, request, queryset):
        for obj in queryset:
            audit(request.user.username,
                  'NodePasswordExpiry:{}/{}'.format(obj.node_ip, obj.username),
                  'bulk_deleted',
                  'node_type={}'.format(obj.node_type.name if obj.node_type else 'None'))
        super().delete_queryset(request, queryset)


# -------------------------------------------------------------
# TaskJob Admin
# -------------------------------------------------------------

@admin.register(TaskJob)
class TaskJobAdmin(admin.ModelAdmin):
    list_display    = ('id', 'user', 'task_type', 'status_display',
                       'duration_display', 'retry_count', 'created_at')
    list_filter     = ('status', 'task_type')
    search_fields   = ('user__username', 'task_type')
    readonly_fields = ('created_at', 'completed_at', 'duration_seconds',
                       'input_file', 'output_file', 'error_message',
                       'user', 'task_type', 'status', 'retry_count')
    ordering        = ('-created_at',)
    list_per_page   = 30

    def status_display(self, obj):
        colors = {'pending':'gray','running':'blue','completed':'green','failed':'red'}
        return format_html(
            '<span style="color:{};font-weight:bold;">{}</span>',
            colors.get(obj.status, 'black'), obj.status.upper())
    status_display.short_description = 'Status'

    def duration_display(self, obj):
        if obj.duration_seconds is None: return '-'
        if obj.duration_seconds < 60: return '{}s'.format(obj.duration_seconds)
        return '{}m {}s'.format(obj.duration_seconds // 60, obj.duration_seconds % 60)
    duration_display.short_description = 'Duration'

    def has_add_permission(self, request): return False

    def delete_model(self, request, obj):
        audit(request.user.username, 'TaskJob:{}'.format(obj.pk), 'deleted',
              'task_type={} status={} user={}'.format(obj.task_type, obj.status, obj.user.username))
        super().delete_model(request, obj)

    def delete_queryset(self, request, queryset):
        for obj in queryset:
            audit(request.user.username, 'TaskJob:{}'.format(obj.pk), 'bulk_deleted',
                  'task_type={} status={}'.format(obj.task_type, obj.status))
        super().delete_queryset(request, queryset)


# -------------------------------------------------------------
# ExpiryAlertConfig Admin
# -------------------------------------------------------------

@admin.register(ExpiryAlertConfig)
class ExpiryAlertConfigAdmin(admin.ModelAdmin):
    list_display    = ('alert_days', 'recipient_count', 'updated_at', 'updated_by')
    readonly_fields = ('updated_at', 'updated_by')

    fieldsets = (
        ('Alert Settings', {
            #'fields': ('alert_days', 'alert_emails'),
            'fields': ('alert_days', 'to_emails', 'cc_emails', 'bcc_emails', 'alert_emails'),
            'description': (
                'alert_days: nodes expiring within this many days will trigger alert. '
                'alert_emails: one email per line.'
            )
        }),
        ('Audit', {
            'fields': ('updated_at', 'updated_by'),
            'classes': ('collapse',)
        }),
    )

    def recipient_count(self, obj):
        count = len([e for e in obj.alert_emails.splitlines() if e.strip()])
        return '{} recipient(s)'.format(count)
    recipient_count.short_description = 'Recipients'

    def save_model(self, request, obj, form, change):
        obj.updated_by = request.user
        super().save_model(request, obj, form, change)
        action = 'changed' if change else 'added'
        audit(request.user.username, 'ExpiryAlertConfig', action,
              'fields={} alert_days={}'.format(
                  list(form.changed_data) if change else ['(new record)'], obj.alert_days))


# -------------------------------------------------------------
# Pending Users proxy (from previous change request)
# -------------------------------------------------------------

from django.contrib.auth.models import User

class PendingUserProxy(User):
    class Meta:
        proxy        = True
        verbose_name = 'Pending User'
        verbose_name_plural = 'Pending Users (Awaiting Activation)'


@admin.register(PendingUserProxy)
class PendingUserAdmin(admin.ModelAdmin):
    list_display  = ('username', 'email', 'date_joined', 'is_active', 'is_staff')
    list_filter   = ('is_active', 'is_staff')
    search_fields = ('username', 'email')
    ordering      = ('-date_joined',)
    actions       = ['activate_users', 'deactivate_users']
    readonly_fields = ('date_joined', 'last_login')

    def get_queryset(self, request):
        return super().get_queryset(request).filter(is_active=False)

    def activate_users(self, request, queryset):
        updated = queryset.update(is_active=True)
        self.message_user(request, '{} user(s) activated.'.format(updated), messages.SUCCESS)
    activate_users.short_description = 'Activate selected users (allow login)'

    def deactivate_users(self, request, queryset):
        updated = queryset.update(is_active=False)
        self.message_user(request, '{} user(s) deactivated.'.format(updated), messages.WARNING)
    deactivate_users.short_description = 'Deactivate selected users'


# -------------------------------------------------------------
# Admin site branding
# -------------------------------------------------------------

admin.site.site_header = 'PAMS - Admin'
admin.site.site_title  = 'PAMS Admin'
admin.site.index_title = 'Administration'

from . import admin_rbac 