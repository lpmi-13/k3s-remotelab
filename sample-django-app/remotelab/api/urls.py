from django.urls import path, include
from rest_framework.routers import DefaultRouter
from . import views

# Create a router for viewsets
router = DefaultRouter()
router.register(r'products', views.ProductViewSet, basename='product')
router.register(r'inventory', views.InventoryViewSet, basename='inventory')

urlpatterns = [
    # Health and info endpoints
    path('health/', views.health_check, name='health_check'),
    path('system/', views.system_info, name='system_info'),
    path('info/', views.api_info, name='api_info'),

    # Task status endpoint
    path('tasks/<str:task_id>/', views.task_status, name='task_status'),

    # Include router URLs
    path('', include(router.urls)),
]
