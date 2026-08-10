from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('dashboard', '0003_nodetype_fk_migration'),
    ]

    operations = [
        migrations.AddField(
            model_name='nodetype',
            name='updated_by',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='nodetype_updates',
                to=settings.AUTH_USER_MODEL,
            ),
        ),
    ]
