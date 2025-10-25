from django.contrib import admin
from django.urls import path, include
from remotelab.api.views import landing_page

urlpatterns = [
    path('', landing_page, name='landing_page'),
    path('admin/', admin.site.urls),
    path('api/', include('remotelab.api.urls')),
    path('metrics', include('django_prometheus.urls')),
]