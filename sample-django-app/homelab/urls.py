from django.contrib import admin
from django.urls import path, include
from homelab.api.views import landing_page

urlpatterns = [
    path('', landing_page, name='landing_page'),
    path('admin/', admin.site.urls),
    path('api/', include('homelab.api.urls')),
    path('metrics', include('django_prometheus.urls')),
]