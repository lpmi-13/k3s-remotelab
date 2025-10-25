from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.core.cache import cache
from django.shortcuts import render
import os
import time
import platform
import version


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
        'description': 'Simple Django REST API for K3s remotelab demo',
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