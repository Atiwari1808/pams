"""
dashboard/migrations/0005_taskjob_terminate_fields.py   (NEW FILE)

Adds the fields needed for the Terminate-Job feature:
  * process_pid    — PID of the running bash process group
  * terminated_by  — staff user who terminated it
  * terminated_at  — timestamp
And adds 'terminated' to the status choices.

Run:  python manage.py migrate
"""
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('dashboard', '0004_nodetype_updated_by'),
    ]

    operations = [
        migrations.AddField(
            model_name='taskjob',
            name='process_pid',
            field=models.IntegerField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='taskjob',
            name='terminated_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='taskjob',
            name='terminated_by',
            field=models.ForeignKey(
                blank=True, null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='terminated_jobs',
                to=settings.AUTH_USER_MODEL,
            ),
        ),
        migrations.AlterField(
            model_name='taskjob',
            name='status',
            field=models.CharField(
                choices=[
                    ('pending', 'Pending'),
                    ('running', 'Running'),
                    ('completed', 'Completed'),
                    ('failed', 'Failed'),
                    ('terminated', 'Terminated'),
                ],
                default='pending', max_length=20,
            ),
        ),
    ]
