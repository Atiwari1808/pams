from django.urls import path
from . import views, log_explorer
from .views import LoginUser, logout_view # Import your new LDAP class and logout function

app_name = 'dashboard'

urlpatterns = [
    # ---------------------------------------------------------
    # Authentication (LDAP + Local Fallback)
    # ---------------------------------------------------------
    # Points to your new Class-Based View for LDAP support
    path('login/', LoginUser.as_view(), name='login'),
    path('logout/', logout_view, name='logout'),
    path('register/', views.register_view, name='register'),

    # ---------------------------------------------------------
    # Main Dashboard
    # ---------------------------------------------------------
    path('',           views.dashboard, name='dashboard'),
    path('dashboard/', views.dashboard, name='dashboard'),

    # ---------------------------------------------------------
    # Task Endpoints (Scripts)
    # ---------------------------------------------------------
    path('login-check/',        views.login_check,        name='login_check'),
    path('reachability-check/', views.reachability_check, name='reachability_check'),
    path('update-password/',    views.update_password,    name='update_password'),
    path('reset-password/',     views.reset_password,     name='reset_password'),

    # Sample CSV downloads
    path('download-sample/<str:task_type>/', views.download_sample, name='download_sample'),
    

    # ---------------------------------------------------------
    # Job Status & Output
    # ---------------------------------------------------------
    path('job/<int:job_id>/status/',   views.job_status,      name='job_status'),
    path('job/<int:job_id>/download/', views.download_output,  name='download_output'),
    path('job/<int:job_id>/terminate/', views.terminate_job, name='terminate_job'),
    # ---------------------------------------------------------
    # Logs & Password Expiry Management (Staff Only)
    # ---------------------------------------------------------
    path('logs/', views.view_logs, name='view_logs'),
    path('log-explorer/',          log_explorer.browse,    name='log_explorer'),
    path('log-explorer/view/',     log_explorer.view_file, name='log_explorer_view'),
    path('log-explorer/download/', log_explorer.download,  name='log_explorer_download'),

    
    # Password Expiry Config and Table
    path('password-expiry/',              views.password_expiry_config, name='password_expiry_config'),
    path('password-expiry/table/',        views.password_expiry_table,  name='password_expiry_table'),
    path('password-expiry/run-now/',      views.run_expiry_check_now,   name='run_expiry_check_now'),
    path('password-expiry/upload-csv/',   views.upload_expiry_csv,      name='upload_expiry_csv'),
    path('password-expiry/update-csv/',   views.update_expiry_csv,      name='update_expiry_csv'),
    path('password-expiry/download-csv-admin/', views.download_expiry_csv_admin, name='download_expiry_csv_admin'),
    path('password-expiry/download-csv-user/',  views.download_expiry_csv_user,  name='download_expiry_csv_user'),
    # Sample CSV downloads
    path('sample-full-expiry/', views.download_full_expiry_sample, name='download_full_expiry_sample'),
    path('sample-partial-expiry/', views.download_partial_expiry_sample, name='download_partial_expiry_sample'),

    # NodeType bulk update
    path('password-expiry/bulk-update-node-type/', views.bulk_update_node_type, name='bulk_update_node_type'),

    # Node activate/deactivate toggle
    path('password-expiry/toggle-node/<int:node_id>/', views.toggle_node_active, name='toggle_node_active'),
]
