# Generated manually to handle CharField -> ForeignKey migration
# for node_type field in NodePasswordExpiry
# Splits into 3 steps:
#   1. Schema changes (NodeType table, new columns, etc.)
#   2. Data migration (create NodeType rows, set FKs)
#   3. Drop old node_type CharField, rename new FK column

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


def create_node_types_and_migrate(apps, schema_editor):
    """
    - Read distinct (node_type string, policy_days) from old column
    - Create NodeType rows
    - Set node_type_new_id FK on each row
    """
    db = schema_editor.connection.alias

    NodeType = apps.get_model('dashboard', 'NodeType')
    NodePasswordExpiry = apps.get_model('dashboard', 'NodePasswordExpiry')

    # Build mapping: node_type_string -> NodeType instance
    # Use (node_type_string, policy_days) pairs so each type keeps its days
    mapping = {}
    for node in NodePasswordExpiry.objects.using(db).all():
        key = node.node_type_old or ''
        if key and key not in mapping:
            nt, _ = NodeType.objects.using(db).get_or_create(
                name=key,
                defaults={'policy_days': node.policy_days_old or 90}
            )
            mapping[key] = nt

    # Now set the FK for each node
    for node in NodePasswordExpiry.objects.using(db).all():
        key = node.node_type_old or ''
        if key and key in mapping:
            node.node_type_new = mapping[key]
            node.save(using=db)


def reverse_migrate(apps, schema_editor):
    """Reverse: copy node_type name back to node_type_old."""
    db = schema_editor.connection.alias
    NodePasswordExpiry = apps.get_model('dashboard', 'NodePasswordExpiry')
    for node in NodePasswordExpiry.objects.using(db).all():
        if node.node_type_new:
            node.node_type_old = node.node_type_new.name
            node.save(using=db)


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('dashboard', '0002_nodepasswordexpiry'),
    ]

    operations = [

        # -- Step 1a: Create NodeType table -------------------
        migrations.CreateModel(
            name='NodeType',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True,
                                        serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=100, unique=True)),
                ('policy_days', models.PositiveIntegerField(default=90)),
                ('default_last_reset_date', models.DateField(
                    blank=True, null=True,
                    help_text='Bulk-set last reset date for all nodes of this type'
                )),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name': 'Node type',
                'verbose_name_plural': 'Node types',
                'ordering': ['name'],
            },
        ),

        # -- Step 1b: Rename old node_type CharField ----------
        # so we can still read it during data migration
        migrations.RenameField(
            model_name='nodepasswordexpiry',
            old_name='node_type',
            new_name='node_type_old',
        ),

        # -- Step 1c: Rename policy_days so we can read it ----
        migrations.RenameField(
            model_name='nodepasswordexpiry',
            old_name='policy_days',
            new_name='policy_days_old',
        ),

        # -- Step 1d: Add new FK column (nullable first) ------
        migrations.AddField(
            model_name='nodepasswordexpiry',
            name='node_type_new',
            field=models.ForeignKey(
                blank=True, null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name='nodes',
                to='dashboard.NodeType',
            ),
        ),

        # -- Step 1e: Add other new fields --------------------
        migrations.AddField(
            model_name='nodepasswordexpiry',
            name='is_active',
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name='taskjob',
            name='duration_seconds',
            field=models.IntegerField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='taskjob',
            name='retry_count',
            field=models.IntegerField(default=0),
        ),

        # -- Step 1f: Fix node_ip field -----------------------
        migrations.AlterField(
            model_name='nodepasswordexpiry',
            name='node_ip',
            field=models.GenericIPAddressField(unpack_ipv4=True),
        ),

        # -- Step 1g: task_type max_length --------------------
        migrations.AlterField(
            model_name='taskjob',
            name='task_type',
            field=models.CharField(max_length=100),
        ),

        # -- Step 1h: PasswordExpiryConfig field fixes --------
        migrations.AlterField(
            model_name='passwordexpiryconfig',
            name='alert_days_before',
            field=models.CharField(default='7', max_length=50),
        ),
        migrations.AlterField(
            model_name='passwordexpiryconfig',
            name='alert_emails',
            field=models.TextField(blank=True),
        ),
        migrations.AlterField(
            model_name='passwordexpiryconfig',
            name='excel_file',
            field=models.FileField(blank=True, upload_to='password_expiry/'),
        ),

        # -- Step 1i: Create ExpiryAlertConfig ----------------
        migrations.CreateModel(
            name='ExpiryAlertConfig',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True,
                                        serialize=False, verbose_name='ID')),
                ('alert_days', models.PositiveIntegerField(default=7)),
                ('alert_emails', models.TextField(
                    blank=True, help_text='One email per line')),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('updated_by', models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    to=settings.AUTH_USER_MODEL,
                )),
            ],
            options={'verbose_name': 'Expiry alert config'},
        ),

        # -- Step 2: Data migration ----------------------------
        # Creates NodeType rows and sets node_type_new FK
        migrations.RunPython(
            create_node_types_and_migrate,
            reverse_migrate,
        ),

        # -- Step 3a: Remove old CharField --------------------
        migrations.RemoveField(
            model_name='nodepasswordexpiry',
            name='node_type_old',
        ),

        # -- Step 3b: Remove old policy_days column -----------
        migrations.RemoveField(
            model_name='nodepasswordexpiry',
            name='policy_days_old',
        ),

        # -- Step 3c: Rename node_type_new ? node_type --------
        migrations.RenameField(
            model_name='nodepasswordexpiry',
            old_name='node_type_new',
            new_name='node_type',
        ),

        # -- Step 3d: Fix model options ------------------------
        migrations.AlterModelOptions(
            name='nodepasswordexpiry',
            options={
                'ordering': ['node_ip', 'username'],
                'verbose_name': 'Node password expiry',
                'verbose_name_plural': 'Node password expiries',
            },
        ),
    ]
