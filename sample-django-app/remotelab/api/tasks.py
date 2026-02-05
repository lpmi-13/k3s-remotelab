import logging
from celery import shared_task
from django.db import models as db_models
from django.utils import timezone

logger = logging.getLogger(__name__)


@shared_task
def check_reorder_levels():
    """
    Periodic task to check inventory levels and trigger reorder alerts.
    Designed to run via Celery Beat schedule.
    """
    from .models import Inventory

    low_stock_items = Inventory.objects.filter(
        quantity__lte=db_models.F('reorder_point'),
        product__is_active=True
    ).select_related('product')

    alerts = []
    for inventory in low_stock_items:
        alert = {
            'product_sku': inventory.product.sku,
            'product_name': inventory.product.name,
            'location': inventory.location or 'N/A',
            'current_quantity': inventory.quantity,
            'reorder_point': inventory.reorder_point
        }
        alerts.append(alert)
        logger.warning(f"Low stock alert: {alert}")

    logger.info(f"Reorder check complete: {len(alerts)} items below reorder point")
    return {
        'status': 'success',
        'checked_at': timezone.now().isoformat(),
        'alerts_count': len(alerts),
        'alerts': alerts
    }


@shared_task
def generate_inventory_report():
    """
    Generate inventory report asynchronously.
    """
    from .models import Inventory
    from decimal import Decimal

    logger.info("Generating inventory report")

    queryset = Inventory.objects.select_related('product')

    report_data = []
    total_value = Decimal('0.00')

    for inventory in queryset:
        item_value = inventory.quantity * inventory.product.price
        total_value += item_value

        report_data.append({
            'location': inventory.location or 'N/A',
            'product_sku': inventory.product.sku,
            'product_name': inventory.product.name,
            'quantity': inventory.quantity,
            'unit_price': str(inventory.product.price),
            'total_value': str(item_value),
            'needs_reorder': inventory.needs_reorder
        })

    report = {
        'generated_at': timezone.now().isoformat(),
        'total_items': len(report_data),
        'total_value': str(total_value),
        'items': report_data
    }

    logger.info(f"Inventory report generated: {len(report_data)} items, total value: {total_value}")
    return report
