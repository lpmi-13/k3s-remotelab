from rest_framework.decorators import api_view, permission_classes, action
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework import viewsets, status
from django.core.cache import cache
from django.shortcuts import render
import os
import time
import platform
import version

from .models import Product, Inventory
from .serializers import (
    ProductSerializer,
    InventorySerializer,
    InventoryAdjustSerializer,
)


# ============================================================
# Health and Info endpoints
# ============================================================

@api_view(['GET'])
@permission_classes([AllowAny])
def health_check(request):
    """Health check endpoint for Kubernetes probes."""
    return Response({
        'status': 'healthy',
        'service': 'remotelab-api',
        'timestamp': time.time()
    })


@api_view(['GET'])
@permission_classes([AllowAny])
def system_info(request):
    """System information endpoint with Redis caching."""
    cache_key = 'system_info'
    cached_info = cache.get(cache_key)

    if not cached_info:
        cached_info = {
            'hostname': os.uname().nodename,
            'python_version': platform.python_version(),
            'platform': platform.platform(),
            'architecture': platform.architecture()[0],
            'cache_status': 'miss',
            'timestamp': time.time()
        }
        # Cache for 5 minutes
        cache.set(cache_key, cached_info, 300)
    else:
        cached_info['cache_status'] = 'hit'

    return Response(cached_info)


@api_view(['GET'])
@permission_classes([AllowAny])
def api_info(request):
    """API information and available endpoints."""
    return Response({
        'name': 'Remotelab Django API',
        'version': version.get_version(),
        'commit': version.get_commit_sha(),
        'build_date': version.get_build_date(),
        'description': 'Simple inventory management API for K3s demo',
        'endpoints': {
            'health': '/api/health/',
            'system': '/api/system/',
            'info': '/api/info/',
            'metrics': '/metrics',
            'admin': '/admin/',
            'graphql': '/graphql/',
            'products': '/api/products/',
            'inventory': '/api/inventory/',
            'trigger_reorder_check': '/api/tasks/reorder-check/ [POST]',
            'trigger_inventory_report': '/api/tasks/inventory-report/ [POST]',
            'task_status': '/api/tasks/{task_id}/status/',
        },
        'features': [
            'Health checks',
            'System information',
            'Redis caching',
            'Prometheus metrics',
            'Product catalog',
            'Inventory tracking',
            'GraphQL API',
            'Celery async tasks',
        ]
    })


def landing_page(request):
    """Landing page showing version information and available endpoints."""
    context = {
        'commit_sha': version.get_commit_sha(),
        'build_date': version.get_build_date(),
        'endpoints': [
            {
                'url': '/django/api/health/',
                'description': 'Health check endpoint for monitoring'
            },
            {
                'url': '/django/api/system/',
                'description': 'System information with Redis caching'
            },
            {
                'url': '/django/api/info/',
                'description': 'API information and version details'
            },
            {
                'url': '/django/graphql/',
                'description': 'GraphQL API endpoint with GraphiQL'
            },
            {
                'url': '/django/api/products/',
                'description': 'Product catalog REST API'
            },
            {
                'url': '/django/api/inventory/',
                'description': 'Inventory tracking REST API'
            },
            {
                'url': '/django/api/tasks/reorder-check/',
                'description': 'Trigger reorder check (POST)'
            },
            {
                'url': '/django/api/tasks/inventory-report/',
                'description': 'Trigger inventory report (POST)'
            },
            {
                'url': '/django/metrics',
                'description': 'Prometheus metrics endpoint'
            },
            {
                'url': '/django/admin/',
                'description': 'Django admin interface'
            }
        ]
    }
    return render(request, 'index.html', context)


# ============================================================
# Domain ViewSets
# ============================================================

class ProductViewSet(viewsets.ModelViewSet):
    """
    ViewSet for managing products.
    """
    queryset = Product.objects.all()
    serializer_class = ProductSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        queryset = super().get_queryset()
        is_active = self.request.query_params.get('is_active')
        sku = self.request.query_params.get('sku')
        if is_active is not None:
            queryset = queryset.filter(is_active=is_active.lower() == 'true')
        if sku:
            queryset = queryset.filter(sku__icontains=sku)
        return queryset


class InventoryViewSet(viewsets.ModelViewSet):
    """
    ViewSet for managing inventory.
    """
    queryset = Inventory.objects.select_related('product').all()
    serializer_class = InventorySerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        queryset = super().get_queryset()
        product_id = self.request.query_params.get('product_id')
        low_stock = self.request.query_params.get('low_stock')

        if product_id:
            queryset = queryset.filter(product_id=product_id)
        if low_stock and low_stock.lower() == 'true':
            from django.db.models import F
            queryset = queryset.filter(quantity__lte=F('reorder_point'))
        return queryset

    @action(detail=True, methods=['post'])
    def adjust_stock(self, request, pk=None):
        """Adjust inventory stock by a given amount."""
        inventory = self.get_object()
        serializer = InventoryAdjustSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        adjustment = serializer.validated_data['adjustment']
        new_quantity = max(0, inventory.quantity + adjustment)
        inventory.quantity = new_quantity
        inventory.save()

        return Response(InventorySerializer(inventory).data)


# ============================================================
# Celery task endpoints
# ============================================================

@api_view(['POST'])
@permission_classes([AllowAny])
def trigger_reorder_check(request):
    """Trigger the reorder level check task asynchronously."""
    from .tasks import check_reorder_levels

    result = check_reorder_levels.delay()
    return Response({
        'task_id': result.id,
        'status': 'submitted',
        'task': 'check_reorder_levels',
    }, status=status.HTTP_202_ACCEPTED)


@api_view(['POST'])
@permission_classes([AllowAny])
def trigger_inventory_report(request):
    """Trigger the inventory report generation task asynchronously."""
    from .tasks import generate_inventory_report

    result = generate_inventory_report.delay()
    return Response({
        'task_id': result.id,
        'status': 'submitted',
        'task': 'generate_inventory_report',
    }, status=status.HTTP_202_ACCEPTED)


@api_view(['GET'])
@permission_classes([AllowAny])
def task_status(request, task_id):
    """Get the status of an async task."""
    from celery.result import AsyncResult

    result = AsyncResult(task_id)

    response_data = {
        'task_id': task_id,
        'status': result.status,
    }

    if result.ready():
        response_data['result'] = result.result

    return Response(response_data)
