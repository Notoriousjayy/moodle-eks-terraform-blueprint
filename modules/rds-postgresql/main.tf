terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

locals {
  pg_major = try(regex("^([0-9]+)", var.engine_version)[0], "16")
  family   = "postgres${local.pg_major}"

  master_password_final = coalesce(var.master_password, random_password.master.result)

  # Compat-safe identifier sanitizer
  db_identifier = join("-", regexall("[a-z0-9]+", lower(var.name)))

  # Kept for backwards compatibility (not used for the Secret name anymore)
  secret_name = coalesce(var.secret_name, "${var.name}-master-credentials")
  common_tags = merge({ "Name" = var.name }, var.tags)
}

# Short, stable suffix to avoid Secret name collisions
resource "random_id" "secret_suffix" {
  byte_length = 3
  keepers = {
    base = var.name
  }
}

# Suffix for final snapshot identifier (only referenced if skip_final_snapshot = false)
resource "random_id" "final_snap_suffix" {
  byte_length = 4
}

# Password generator that avoids '/', '@', '\"', and space
resource "random_password" "master" {
  length  = 20
  special = true
  # Allowed specials per RDS rules (exclude '/', '@', '\"', and space)
  override_special = "!#$%^&*()-_=+[]{}:;,.?~%"
  keepers = {
    username = var.master_username
  }
}

# DB subnet group across private subnets (same VPC as EKS)
resource "aws_db_subnet_group" "this" {
  name       = "${local.db_identifier}-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

# Security group for RDS PostgreSQL
resource "aws_security_group" "this" {
  name        = "${local.db_identifier}-rds-sg"
  description = "RDS PostgreSQL SG for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

# Ingress from allowed SGs
resource "aws_security_group_rule" "ingress_sg" {
  for_each                 = toset(var.allowed_security_group_ids)
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
  security_group_id        = aws_security_group.this.id
  source_security_group_id = each.value
  description              = "Postgres from SG ${each.value}"
}

# Ingress from allowed CIDRs (use sparingly)
resource "aws_security_group_rule" "ingress_cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 5432
  to_port           = 5432
  security_group_id = aws_security_group.this.id
  cidr_blocks       = [each.value]
  description       = "Postgres from CIDR ${each.value}"
}

# Egress: allow outbound (to S3/KMS/etc. as needed)
resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  security_group_id = aws_security_group.this.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Egress"
}

# Optional parameter group
resource "aws_db_parameter_group" "this" {
  count  = length(var.parameter_overrides) > 0 ? 1 : 0
  name   = "${local.db_identifier}-pg"
  family = local.family
  tags   = local.common_tags

  dynamic "parameter" {
    for_each = var.parameter_overrides
    content {
      name  = parameter.key
      value = parameter.value
    }
  }
}

# Secrets Manager secret for master credentials (username/password only)
# Use caller-provided name if set; otherwise append a random suffix to avoid "scheduled for deletion" conflicts
resource "aws_secretsmanager_secret" "master" {
  count       = var.create_master_secret ? 1 : 0
  name        = var.secret_name != null ? var.secret_name : "${var.name}-master-credentials-${random_id.secret_suffix.hex}"
  description = "Master credentials for ${var.name} PostgreSQL on RDS"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "master" {
  count     = var.create_master_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.master[0].id
  secret_string = jsonencode({
    username = var.master_username
    password = local.master_password_final
  })
}

# RDS PostgreSQL instance
resource "aws_db_instance" "this" {
  identifier     = local.db_identifier
  engine         = "postgres"
  engine_version = var.engine_version
  db_name        = var.db_name
  username       = var.master_username
  password       = local.master_password_final
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = var.storage_encrypted
  kms_key_id            = var.kms_key_id
  storage_type          = var.storage_type
  iops                  = var.iops

  multi_az            = var.multi_az
  publicly_accessible = var.publicly_accessible
  port                = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  backup_retention_period    = var.backup_retention_period
  backup_window              = var.backup_window
  maintenance_window         = var.maintenance_window
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  deletion_protection        = var.deletion_protection

  performance_insights_enabled    = var.enable_performance_insights
  performance_insights_kms_key_id = var.performance_insights_kms_key_id

  # --- NEW: handle final snapshot requirements on destroy ---
  skip_final_snapshot = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : format(
    "%s-%s",
    coalesce(var.final_snapshot_identifier_prefix, local.db_identifier),
    random_id.final_snap_suffix.hex
  )

  parameter_group_name                = length(var.parameter_overrides) > 0 ? aws_db_parameter_group.this[0].name : null
  iam_database_authentication_enabled = var.iam_database_authentication_enabled

  apply_immediately = false

  tags = local.common_tags

  lifecycle {
    ignore_changes = [password]
  }
}
