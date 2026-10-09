"""Add explicitly confirmed assistant memory to user preferences."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
revision = "20261009110000"
down_revision = "20251004130000"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("user_preferences", sa.Column("assistant_memory", postgresql.JSONB(), nullable=True))


def downgrade():
    op.drop_column("user_preferences", "assistant_memory")
