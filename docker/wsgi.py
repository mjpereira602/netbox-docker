import os

from django.core.wsgi import get_wsgi_application
from proxyprefix.wsgi import ReverseProxiedApp

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "netbox.settings")

#application = get_wsgi_application()
application = ReverseProxiedApp(get_wsgi_application())
