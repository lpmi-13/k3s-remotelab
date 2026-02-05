from django.test import TestCase
from django.urls import reverse
from django.contrib.auth.models import User
from rest_framework.test import APITestCase
from rest_framework import status
from decimal import Decimal

from .models import Product, Inventory


class HealthCheckTestCase(APITestCase):
    """Test cases for the health check endpoint."""

    def test_health_check_endpoint(self):
        """Test that health check endpoint returns 200 and expected data."""
        url = reverse('health_check')
        response = self.client.get(url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['status'], 'healthy')
        self.assertEqual(response.data['service'], 'remotelab-api')
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
        self.assertEqual(response.data['name'], 'Remotelab Django API')
        self.assertIn('endpoints', response.data)
        self.assertIn('features', response.data)
        self.assertIn('graphql', response.data['endpoints'])
        self.assertIn('products', response.data['endpoints'])
        self.assertIn('inventory', response.data['endpoints'])


class ProductModelTestCase(TestCase):
    """Test cases for the Product model."""

    def test_product_creation(self):
        """Test creating a product."""
        product = Product.objects.create(
            sku='TEST-001',
            name='Test Product',
            description='A test product',
            price=Decimal('99.99'),
            is_active=True
        )
        self.assertEqual(product.sku, 'TEST-001')
        self.assertEqual(product.name, 'Test Product')
        self.assertEqual(product.price, Decimal('99.99'))
        self.assertTrue(product.is_active)
        self.assertEqual(str(product), 'TEST-001 - Test Product')


class InventoryModelTestCase(TestCase):
    """Test cases for the Inventory model."""

    def setUp(self):
        self.product = Product.objects.create(
            sku='TEST-001',
            name='Test Product',
            price=Decimal('99.99')
        )

    def test_inventory_creation(self):
        """Test creating an inventory record."""
        inventory = Inventory.objects.create(
            product=self.product,
            quantity=50,
            reorder_point=10,
            location='Aisle 3, Shelf B'
        )
        self.assertEqual(inventory.product, self.product)
        self.assertEqual(inventory.quantity, 50)
        self.assertEqual(inventory.reorder_point, 10)
        self.assertEqual(inventory.location, 'Aisle 3, Shelf B')
        self.assertFalse(inventory.needs_reorder)

    def test_needs_reorder_property(self):
        """Test the needs_reorder property."""
        inventory = Inventory.objects.create(
            product=self.product,
            quantity=5,
            reorder_point=10
        )
        self.assertTrue(inventory.needs_reorder)

        inventory.quantity = 15
        inventory.save()
        self.assertFalse(inventory.needs_reorder)


class ProductAPITestCase(APITestCase):
    """Test cases for the Product API."""

    def setUp(self):
        self.user = User.objects.create_user(username='testuser', password='testpass')
        self.client.force_authenticate(user=self.user)

        self.product = Product.objects.create(
            sku='TEST-001',
            name='Test Product',
            price=Decimal('99.99')
        )

    def test_list_products(self):
        """Test listing products."""
        url = reverse('product-list')
        response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)

    def test_retrieve_product(self):
        """Test retrieving a single product."""
        url = reverse('product-detail', args=[self.product.id])
        response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['sku'], 'TEST-001')

    def test_create_product(self):
        """Test creating a product."""
        url = reverse('product-list')
        data = {
            'sku': 'TEST-002',
            'name': 'New Product',
            'description': 'A new test product',
            'price': '149.99',
            'is_active': True
        }
        response = self.client.post(url, data)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(Product.objects.count(), 2)


class InventoryAPITestCase(APITestCase):
    """Test cases for the Inventory API."""

    def setUp(self):
        self.user = User.objects.create_user(username='testuser', password='testpass')
        self.client.force_authenticate(user=self.user)

        self.product = Product.objects.create(
            sku='TEST-001',
            name='Test Product',
            price=Decimal('99.99')
        )

        self.inventory = Inventory.objects.create(
            product=self.product,
            quantity=50,
            reorder_point=10,
            location='Aisle 1'
        )

    def test_list_inventory(self):
        """Test listing inventory."""
        url = reverse('inventory-list')
        response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)

    def test_retrieve_inventory(self):
        """Test retrieving a single inventory record."""
        url = reverse('inventory-detail', args=[self.inventory.id])
        response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['quantity'], 50)

    def test_adjust_stock(self):
        """Test adjusting inventory stock."""
        url = reverse('inventory-adjust-stock', args=[self.inventory.id])
        data = {'adjustment': 10}
        response = self.client.post(url, data)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        self.inventory.refresh_from_db()
        self.assertEqual(self.inventory.quantity, 60)

    def test_adjust_stock_negative(self):
        """Test adjusting inventory stock with negative adjustment."""
        url = reverse('inventory-adjust-stock', args=[self.inventory.id])
        data = {'adjustment': -20}
        response = self.client.post(url, data)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        self.inventory.refresh_from_db()
        self.assertEqual(self.inventory.quantity, 30)

    def test_filter_low_stock(self):
        """Test filtering inventory by low stock."""
        low_stock_inventory = Inventory.objects.create(
            product=Product.objects.create(sku='TEST-002', name='Low Stock', price=Decimal('50.00')),
            quantity=5,
            reorder_point=10
        )

        url = reverse('inventory-list')
        response = self.client.get(url, {'low_stock': 'true'})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]['quantity'], 5)
