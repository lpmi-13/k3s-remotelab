import os

from django.db import connections
from django.http import HttpResponse, JsonResponse
from django.urls import path


def index(_request):
    return JsonResponse(
        {
            "service": "argo-remotelab-django",
            "status": "ok",
        }
    )


def health(_request):
    try:
        with connections["default"].cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception as exc:
        return JsonResponse(
            {
                "status": "unhealthy",
                "database": "unavailable",
                "error": exc.__class__.__name__,
            },
            status=503,
        )

    return JsonResponse(
        {
            "status": "ok",
            "database": "available",
            "environment": os.environ.get("APP_ENVIRONMENT", "production"),
        }
    )


def metrics(_request):
    body = "\n".join(
        [
            "# HELP remotelab_django_up Whether the Django app can serve requests.",
            "# TYPE remotelab_django_up gauge",
            "remotelab_django_up 1",
            "",
        ]
    )
    return HttpResponse(body, content_type="text/plain; version=0.0.4")


urlpatterns = [
    path("", index),
    path("api/health/", health),
    path("metrics", metrics),
]
