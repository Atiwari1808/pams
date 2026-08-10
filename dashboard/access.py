"""
dashboard/access.py   (NEW VERSION — Group-based)
=================================================
Reads access from the user's Django Groups via each Group's GroupProfile.

Superusers ALWAYS pass. Staff pass too if STAFF_BYPASS=True (default) so
existing admins keep working. Set STAFF_BYPASS=False to govern staff by groups.

Usage in views:
    from .access import user_can_card, user_can_flag, user_reset_types
    if not user_can_card(request.user, 'login_check'):
        return HttpResponseForbidden('Your role does not allow this task.')

Templates (via access_context processor):
    {% if access.cards.login_check %} ... {% endif %}
    {% if access.can_view_log_explorer %} ... {% endif %}
"""

STAFF_BYPASS = True

ALL_CARDS = ['login_check', 'reachability_check', 'reset_password', 'update_password']
ALL_RESET_TYPES = ['dns', 'cmm', 'wmg', 'mme', 'huawei_oss','pcg', 'pccsm']
ALL_FLAGS = [
    'can_view_password_expiry',
    'can_edit_alert_config',
    'can_view_logs',
    'can_view_log_explorer',
    'can_access_admin',
]


def _is_privileged(user):
    if not user.is_authenticated:
        return False
    if user.is_superuser:
        return True
    if STAFF_BYPASS and user.is_staff:
        return True
    return False


def _profiles(user):
    """All GroupProfiles for the user's groups (skips groups without one)."""
    if not user.is_authenticated:
        return []
    out = []
    for g in user.groups.all():
        prof = getattr(g, 'pams_profile', None)
        if prof is not None:
            out.append(prof)
    return out


def user_can_card(user, card_key):
    if _is_privileged(user):
        return True
    return any(card_key in p.card_list() for p in _profiles(user))


def user_reset_types(user):
    if _is_privileged(user):
        return set(ALL_RESET_TYPES)
    types = set()
    for p in _profiles(user):
        types.update(p.reset_type_list())
    return types


def user_can_flag(user, flag):
    if _is_privileged(user):
        return True
    return any(getattr(p, flag) for p in _profiles(user))


def access_context(request):
    """Context processor — exposes `access` in every template.
    Add to settings TEMPLATES['OPTIONS']['context_processors']:
        'dashboard.access.access_context'
    """
    u = request.user
    privileged = _is_privileged(u)
    cards = {c: (privileged or user_can_card(u, c)) for c in ALL_CARDS}
    flags = {f: (privileged or user_can_flag(u, f)) for f in ALL_FLAGS}
    return {
        'access': {
            'is_privileged': privileged,
            'cards': cards,
            'reset_types': sorted(user_reset_types(u)),
            **flags,
        }
    }
