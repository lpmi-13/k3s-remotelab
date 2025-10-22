from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.core.cache import cache
import os
import time
import platform


@api_view(['GET'])
@permission_classes([AllowAny])
def health_check(request):
    """Health check endpoint for Kubernetes probes."""
    return Response({
        'status': 'healthy',
        'service': 'homelab-api',
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
        'name': 'Homelab Django API',
        'version': '1.0.0',
        'description': 'Simple Django REST API for K3s homelab demo',
        'endpoints': {
            'health': '/api/health/',
            'system': '/api/system/',
            'info': '/api/info/',
            'metrics': '/metrics',
            'admin': '/admin/'
        },
        'features': [
            'Health checks',
            'System information',
            'Redis caching',
            'Prometheus metrics',
            'Path-based routing support'
        ]
    })