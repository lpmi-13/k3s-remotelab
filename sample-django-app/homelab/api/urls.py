from django.urls import path
from . import views

urlpatterns = [
    path('health/', views.health_check, name='health_check'),
    path('system/', views.system_info, name='system_info'),
    path('info/', views.api_info, name='api_info'),
]