from django.contrib import admin
from django.urls import path, include
from strawberry.django.views import GraphQLView
from remotelab.api.views import landing_page
from remotelab.api.schema import schema

urlpatterns = [
    path('', landing_page, name='landing_page'),
    path('admin/', admin.site.urls),
    path('api/', include('remotelab.api.urls')),
    path('graphql/', GraphQLView.as_view(schema=schema, graphql_ide='graphiql'), name='graphql'),
    path('metrics', include('django_prometheus.urls')),
]
