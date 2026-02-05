from django.db import models
from django.core.validators import MinValueValidator
from decimal import Decimal
import uuid


class Product(models.Model):
    """Items that can be stored in inventory."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    sku = models.CharField(max_length=50, unique=True)
    name = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal('0.00'))]
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['sku']

    def __str__(self):
        return f"{self.sku} - {self.name}"


class Inventory(models.Model):
    """Stock levels for products with location tracking."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name='inventory_records'
    )
    quantity = models.IntegerField(
        default=0,
        validators=[MinValueValidator(0)]
    )
    reorder_point = models.IntegerField(
        default=10,
        validators=[MinValueValidator(0)],
        help_text='Minimum quantity before reorder alert'
    )
    location = models.CharField(
        max_length=100,
        blank=True,
        help_text='Storage location (e.g., Aisle 3, Shelf B)'
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['product']
        verbose_name_plural = 'Inventory'

    def __str__(self):
        return f"{self.product.sku}: {self.quantity}"

    @property
    def needs_reorder(self):
        """Check if inventory is below reorder point."""
        return self.quantity <= self.reorder_point
