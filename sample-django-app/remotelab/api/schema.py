import strawberry
from strawberry import auto
from strawberry.django import type as strawberry_type
from typing import List, Optional
from decimal import Decimal
import uuid

from . import models


# Strawberry types for GraphQL
@strawberry_type(models.Product)
class ProductType:
    id: auto
    sku: auto
    name: auto
    description: auto
    price: auto
    is_active: auto
    created_at: auto
    updated_at: auto


@strawberry_type(models.Inventory)
class InventoryType:
    id: auto
    product: ProductType
    quantity: auto
    reorder_point: auto
    location: auto
    created_at: auto
    updated_at: auto

    @strawberry.field
    def needs_reorder(self) -> bool:
        return self.quantity <= self.reorder_point


# Input types for mutations
@strawberry.input
class ProductInput:
    sku: str
    name: str
    description: Optional[str] = ""
    price: Decimal
    is_active: Optional[bool] = True


@strawberry.input
class InventoryInput:
    product_id: uuid.UUID
    quantity: int
    reorder_point: Optional[int] = 10
    location: Optional[str] = ""


# Query type
@strawberry.type
class Query:
    @strawberry.field
    def products(self, is_active: Optional[bool] = None) -> List[ProductType]:
        qs = models.Product.objects.all()
        if is_active is not None:
            qs = qs.filter(is_active=is_active)
        return list(qs)

    @strawberry.field
    def product(self, id: Optional[uuid.UUID] = None, sku: Optional[str] = None) -> Optional[ProductType]:
        try:
            if id:
                return models.Product.objects.get(id=id)
            elif sku:
                return models.Product.objects.get(sku=sku)
            return None
        except models.Product.DoesNotExist:
            return None

    @strawberry.field
    def inventory(
        self,
        product_id: Optional[uuid.UUID] = None,
        low_stock_only: Optional[bool] = False
    ) -> List[InventoryType]:
        from django.db.models import F
        qs = models.Inventory.objects.select_related('product')
        if product_id:
            qs = qs.filter(product_id=product_id)
        if low_stock_only:
            qs = qs.filter(quantity__lte=F('reorder_point'))
        return list(qs)


# Mutation response types
@strawberry.type
class ProductResponse:
    success: bool
    message: str
    product: Optional[ProductType] = None


@strawberry.type
class InventoryResponse:
    success: bool
    message: str
    inventory: Optional[InventoryType] = None


# Mutation type
@strawberry.type
class Mutation:
    @strawberry.mutation
    def create_product(self, input: ProductInput) -> ProductResponse:
        try:
            product = models.Product.objects.create(
                sku=input.sku,
                name=input.name,
                description=input.description or "",
                price=input.price,
                is_active=input.is_active if input.is_active is not None else True
            )
            return ProductResponse(success=True, message="Product created", product=product)
        except Exception as e:
            return ProductResponse(success=False, message=str(e))

    @strawberry.mutation
    def update_product(self, id: uuid.UUID, input: ProductInput) -> ProductResponse:
        try:
            product = models.Product.objects.get(id=id)
            product.sku = input.sku
            product.name = input.name
            if input.description is not None:
                product.description = input.description
            product.price = input.price
            if input.is_active is not None:
                product.is_active = input.is_active
            product.save()
            return ProductResponse(success=True, message="Product updated", product=product)
        except models.Product.DoesNotExist:
            return ProductResponse(success=False, message="Product not found")
        except Exception as e:
            return ProductResponse(success=False, message=str(e))

    @strawberry.mutation
    def create_inventory(self, input: InventoryInput) -> InventoryResponse:
        try:
            inventory = models.Inventory.objects.create(
                product_id=input.product_id,
                quantity=input.quantity,
                reorder_point=input.reorder_point or 10,
                location=input.location or ""
            )
            return InventoryResponse(success=True, message="Inventory created", inventory=inventory)
        except Exception as e:
            return InventoryResponse(success=False, message=str(e))

    @strawberry.mutation
    def update_inventory(self, id: uuid.UUID, input: InventoryInput) -> InventoryResponse:
        try:
            inventory = models.Inventory.objects.get(id=id)
            inventory.product_id = input.product_id
            inventory.quantity = input.quantity
            if input.reorder_point is not None:
                inventory.reorder_point = input.reorder_point
            if input.location is not None:
                inventory.location = input.location
            inventory.save()
            return InventoryResponse(success=True, message="Inventory updated", inventory=inventory)
        except models.Inventory.DoesNotExist:
            return InventoryResponse(success=False, message="Inventory not found")
        except Exception as e:
            return InventoryResponse(success=False, message=str(e))

    @strawberry.mutation
    def adjust_inventory(
        self,
        inventory_id: uuid.UUID,
        adjustment: int
    ) -> InventoryResponse:
        try:
            inventory = models.Inventory.objects.get(id=inventory_id)
            inventory.quantity = max(0, inventory.quantity + adjustment)
            inventory.save()
            return InventoryResponse(success=True, message="Inventory adjusted", inventory=inventory)
        except models.Inventory.DoesNotExist:
            return InventoryResponse(success=False, message="Inventory record not found")
        except Exception as e:
            return InventoryResponse(success=False, message=str(e))


# Create the schema
schema = strawberry.Schema(query=Query, mutation=Mutation)
