"""
Data migration to create periodic tasks for celery-beat.
Sets up the reorder check to run every 5 minutes.
"""
import json
from django.db import migrations


def create_periodic_tasks(apps, schema_editor):
    IntervalSchedule = apps.get_model('django_celery_beat', 'IntervalSchedule')
    PeriodicTask = apps.get_model('django_celery_beat', 'PeriodicTask')

    # Create a 5-minute interval schedule
    schedule, _ = IntervalSchedule.objects.get_or_create(
        every=5,
        period='minutes',
    )

    # Create periodic task for reorder check
    PeriodicTask.objects.get_or_create(
        name='Check reorder levels',
        defaults={
            'task': 'remotelab.api.tasks.check_reorder_levels',
            'interval': schedule,
            'enabled': True,
            'kwargs': json.dumps({}),
        },
    )


def remove_periodic_tasks(apps, schema_editor):
    PeriodicTask = apps.get_model('django_celery_beat', 'PeriodicTask')
    PeriodicTask.objects.filter(name='Check reorder levels').delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0001_initial'),
        ('django_celery_beat', '0019_alter_periodictasks_options'),
    ]

    operations = [
        migrations.RunPython(create_periodic_tasks, remove_periodic_tasks),
    ]
