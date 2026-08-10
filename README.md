# NetOps Dashboard – Django Project

A Django-based web dashboard for network operations teams.  
Features: login/auth, 4 task runners (CSV in → bash script → CSV out), and daily password-expiry email alerts.

---

## 📁 Project Structure

```
netops_project/
├── manage.py
├── requirements.txt
├── db.sqlite3                  ← auto-created on first migrate
├── media/
│   ├── uploads/                ← user-uploaded CSVs
│   └── outputs/                ← task output CSVs
├── bash_scripts/               ← ⭐ PUT YOUR SCRIPTS HERE
│   ├── login_check.sh
│   ├── reachability_check.sh
│   ├── reset_password.sh
│   └── update_password.sh
├── netops_project/
│   ├── settings.py
│   ├── urls.py
│   └── wsgi.py
└── dashboard/
    ├── models.py
    ├── views.py
    ├── urls.py
    ├── admin.py
    └── templates/dashboard/
        ├── base.html
        ├── login.html
        ├── dashboard.html
        └── password_expiry.html
```

---

## 🚀 Quick Setup

### 1. Install Python dependencies

```bash
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

### 2. Configure settings

Open `netops_project/settings.py` and update:

```python
# Email (for password expiry alerts)
EMAIL_HOST_USER     = 'your-email@gmail.com'
EMAIL_HOST_PASSWORD = 'your-app-password'      # Gmail App Password
DEFAULT_FROM_EMAIL  = 'NetOps <your-email@gmail.com>'

# Alert recipients (fallback if not set in UI)
PASSWORD_EXPIRY_ALERT_TO = ['admin@yourcompany.com']
```

### 3. Initialize database

```bash
python manage.py migrate
python manage.py createsuperuser    # creates admin login
```

### 4. Make bash scripts executable

```bash
chmod +x bash_scripts/*.sh
```

### 5. Run the server

```bash
python manage.py runserver 0.0.0.0:8000
```

Visit: **http://localhost:8000**

---

## 🔗 Linking Your Bash Scripts

The placeholder scripts in `bash_scripts/` are stubs. Replace the logic inside each one:

| Script | What it receives | What it must write |
|--------|-----------------|---------------------|
| `login_check.sh` | `$1`=input CSV, `$2`=output CSV path | CSV with login results |
| `reachability_check.sh` | same | CSV with reachability results |
| `reset_password.sh` | same | CSV with reset results |
| `update_password.sh` | same | CSV with DB update results |

**Convention**: script must exit `0` on success and the output file `$2` must exist after completion.

---

## ⏰ Password Expiry – Daily Cron

### Step 1: Configure via UI
Go to **Password Expiry** in the sidebar → upload your CSV/XLSX → set alert days → save emails.

### Step 2: Add cron job

```bash
crontab -e
```

Add:

```
0 8 * * * /full/path/to/venv/bin/python /full/path/to/manage.py check_password_expiry >> /var/log/netops_expiry.log 2>&1
```

This runs every day at 8:00 AM and sends emails for passwords expiring in 1, 2, or 3 days.

### Expected CSV/XLSX columns:

| device | username | password_expiry_date |
|--------|----------|---------------------|
| router-01 | admin | 2026-03-01 |
| switch-02 | netops | 2026-03-02 |

Accepted date formats: `YYYY-MM-DD`, `DD/MM/YYYY`, `MM/DD/YYYY`

---

## 📋 URL Reference

| URL | Purpose |
|-----|---------|
| `/login/` | Login page |
| `/dashboard/` | Main dashboard with task buttons |
| `/password-expiry/` | Password expiry config & alert log |
| `/admin/` | Django admin panel |
| `/job/<id>/status/` | JSON API – poll job status |
| `/job/<id>/download/` | Download output CSV |

---

## ⚙️ Gmail App Password Setup

1. Go to Google Account → Security → 2-Step Verification → App Passwords
2. Generate a password for "Mail"
3. Use that 16-char password in `EMAIL_HOST_PASSWORD`

---

## 🛡️ Production Checklist

- [ ] Set `DEBUG = False` in settings.py
- [ ] Set `SECRET_KEY` from environment variable
- [ ] Use PostgreSQL instead of SQLite
- [ ] Configure `ALLOWED_HOSTS` with your domain
- [ ] Run `python manage.py collectstatic`
- [ ] Use Gunicorn + Nginx
