from django.contrib import admin
from .models import Product, Inventory


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ['sku', 'name', 'price', 'is_active', 'created_at']
    list_filter = ['is_active']
    search_fields = ['sku', 'name', 'description']
    ordering = ['sku']


@admin.register(Inventory)
class InventoryAdmin(admin.ModelAdmin):
    list_display = ['product', 'location', 'quantity', 'reorder_point', 'needs_reorder']
    list_filter = ['product__is_active']
    search_fields = ['product__sku', 'product__name', 'location']
    ordering = ['product']

    def needs_reorder(self, obj):
        return obj.needs_reorder
    needs_reorder.boolean = True
