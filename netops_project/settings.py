import os
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

# Load .env from project root (one level above netops_project/)
load_dotenv(BASE_DIR / '.env')

SECRET_KEY = 'django-insecure-change-this-in-production-use-env-variable'
#SECRET_KEY = os.environ.get('DJANGO_SECRET_KEY', 'django-insecure-dev-only-change-me')

DEBUG = True
#DEBUG = os.environ.get('DJANGO_DEBUG', '0') == '1'

ALLOWED_HOSTS = ['*']
#ALLOWED_HOSTS = os.environ.get('DJANGO_ALLOWED_HOSTS', '127.0.0.1,localhost,150.236.9.5').split(',')

# ── Production security (only enforced when DEBUG is False) ──
if not DEBUG:
    SECURE_SSL_REDIRECT = os.environ.get('DJANGO_SSL_REDIRECT', '0') == '1'
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_CONTENT_TYPE_NOSNIFF = True
    SECURE_BROWSER_XSS_FILTER = True
    X_FRAME_OPTIONS = 'DENY'
    SECURE_HSTS_SECONDS = 31536000
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD = True
    CSRF_TRUSTED_ORIGINS = os.environ.get(
        'DJANGO_CSRF_TRUSTED', 'https://150.236.9.5'
    ).split(',')

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'dashboard',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'netops_project.urls'

LDAP_URL = 'INNOIWEGAD00001.ericsson.se'
LDAP_PORT = 636


TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
                'dashboard.access.access_context',
            ],
        },
    },
]

WSGI_APPLICATION = 'netops_project.wsgi.application'

# ─────────────────────────────────────────────────────────────
# Database
# ─────────────────────────────────────────────────────────────
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'Asia/Kolkata'
USE_I18N = True
USE_TZ = True

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# ─────────────────────────────────────────────────────────────
# Static & Media
# ─────────────────────────────────────────────────────────────
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_DIRS = [BASE_DIR / 'static']

MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'

# ─────────────────────────────────────────────────────────────
# Auth redirects
# ─────────────────────────────────────────────────────────────
LOGIN_URL = '/login/'
LOGIN_REDIRECT_URL = '/dashboard/'
LOGOUT_REDIRECT_URL = '/login/'

# ─────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────
BASH_SCRIPTS_DIR = BASE_DIR / 'bash_scripts'

LOG_DIR         = MEDIA_ROOT / 'logs'
APP_LOG_FILE    = LOG_DIR / 'netops.log'
EXPIRY_LOG_FILE = LOG_DIR / 'expiry.log'

os.makedirs(LOG_DIR, exist_ok=True)

# ─────────────────────────────────────────────────────────────
# Task runner config
# ─────────────────────────────────────────────────────────────
TASK_CONFIG = {
    'login_check': {
        'label':          'Login Check',
        'script':         'login_check.sh',
        'sample_file':    'sample_login_check.csv',
        'sample_content': 'Node IP,Node Type,Username,Password,Port\r\n',
    },
    'reachability_check': {
        'label':          'Reachability Check',
        'script':         'reachability_check.sh',
        'sample_file':    'sample_reachability_check.csv',
        'sample_content': 'Ace_server_ip,Node_ip,Port\r\n',
    },
    'update_password': {
        'label':          'DB Password Update',
        'script':         'update_password.sh',
        'sample_file':    'sample_update_password.csv',
        'sample_content': 'node_ip,username,old_password,new_password\r\n',
    },
}

RESET_PASSWORD_SCRIPTS = {
    'dns': 'dns_password_reset.sh',
    'cmm': 'cmm_password_reset.sh',
    'cmg': 'cmg_password_reset.sh',
    'wmg': 'wmg_password_reset.sh',
    'mme': 'mme_password_reset.sh',
    'huawei_oss': 'huawei_oss_password_reset.sh',
    'pcg': 'pcg_password_reset.sh',
    'pccsm': 'pccsm_password_reset.sh',
    'pccmm': 'pccmm_password_reset.sh',
    'epg': 'epg_password_reset.sh',
    'bsc_linux': 'bsc_linux_password_reset.sh',
    'cisco_dns': 'ciscodns_password_reset.sh',
    'ericsson_bc': 'ericsson_bc_password_reset.sh',

}

# ─────────────────────────────────────────────────────────────
# Email
# ─────────────────────────────────────────────────────────────
EMAIL_BACKEND       = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST          = '130.100.151.7'
EMAIL_PORT          = 25
EMAIL_USE_TLS       = False
EMAIL_USE_SSL       = False
EMAIL_HOST_USER     = ''
EMAIL_HOST_PASSWORD = ''
DEFAULT_FROM_EMAIL  = 'password-expiry.alert@ericsson.com'

PASSWORD_EXPIRY_ALERT_DAYS = 15
PASSWORD_EXPIRY_ALERT_TO   = ['abhishek.a.tiwari@ericsson.com','vaishali.saini@ericsson.com']

# ─────────────────────────────────────────────────────────────
# Logging — media/logs/netops.log
# ─────────────────────────────────────────────────────────────
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'standard': {
            'format':  '%(asctime)s [%(levelname)s] %(message)s',
            'datefmt': '%Y-%m-%d %H:%M:%S',
        },
    },
    'handlers': {
        'app_file': {
            'class':     'logging.FileHandler',
            'filename':  str(APP_LOG_FILE),
            'encoding':  'utf-8',
            'formatter': 'standard',
        },
        'console': {
            'class':     'logging.StreamHandler',
            'formatter': 'standard',
        },
    },
    'loggers': {
        'netops': {
            'handlers':  ['app_file', 'console'],
            'level':     'DEBUG',
            'propagate': False,
        },
    },
}
