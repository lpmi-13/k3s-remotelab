from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APITestCase
from rest_framework import status


class HealthCheckTestCase(APITestCase):
    """Test cases for the health check endpoint."""

    def test_health_check_endpoint(self):
        """Test that health check endpoint returns 200 and expected data."""
        url = reverse('health_check')
        response = self.client.get(url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['status'], 'healthy')
        self.assertEqual(response.data['service'], 'homelab-api')
        self.assertIn('timestamp', response.data)


class SystemInfoTestCase(APITestCase):
    """Test cases for the system info endpoint."""

    def test_system_info_endpoint(self):
        """Test that system info endpoint returns 200 and expected data."""
        url = reverse('system_info')
        response = self.client.get(url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn('hostname', response.data)
        self.assertIn('python_version', response.data)
        self.assertIn('cache_status', response.data)


class ApiInfoTestCase(APITestCase):
    """Test cases for the API info endpoint."""

    def test_api_info_endpoint(self):
        """Test that API info endpoint returns 200 and expected data."""
        url = reverse('api_info')
        response = self.client.get(url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['name'], 'Homelab Django API')
        self.assertIn('endpoints', response.data)
        self.assertIn('features', response.data)