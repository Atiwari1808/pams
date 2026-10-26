from ldap3 import Server, Connection, ALL
from django.conf import settings

class Ldap:
    def __init__(self, ldap_url, username, password):
        self.username = username
        self.password = password
        self.ldap_url = ldap_url
        self.data = [] # Instance variable to prevent data leakage between users

        # Port 636 requires SSL
        use_ssl = True if settings.LDAP_PORT == 636 else False
        
        self.server = Server(
            self.ldap_url, 
            port=settings.LDAP_PORT, 
            get_info=ALL, 
            use_ssl=use_ssl
        )
        
        self.conn = Connection(
            self.server, 
            'ericsson\{}'.format(username),
            '{}'.format(self.password),
            auto_bind=True
        )
        
        self.fields = ["cn","sn","department","title", "company","l",
                       "employeeID","manager","mail","displayname","mobile"]

    def ldap_query(self, signum):
        self.conn.search(
            search_base='DC=ericsson,DC=se',
            search_filter='(sAMAccountName={})'.format(signum),
            search_scope='SUBTREE',
            attributes = self.fields
        )
        response = self.conn.response
        # Changed to >= 1 to catch single user results
        if len(response) >= 1:
            return response[0].get('attributes')
        return {}

    def fetchdata(self, signum=None):
        if not signum:
            signum = self.username
            
        user_data = self.ldap_query(signum=signum)
        if user_data:
            self.data.append({signum: user_data})
            if user_data.get('manager'):
                try:
                    manager_signum = user_data.get('manager').split(',')[0].split('=')[1]
                    self.fetchdata(signum=manager_signum)
                except (IndexError, AttributeError):
                    pass
        return self.data