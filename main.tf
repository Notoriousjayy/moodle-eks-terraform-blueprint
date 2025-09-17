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

  # Compat-safe identifier sanitizer (letters/digits only; hyphen-separated)
  db_identifier = join("-", regexall("[a-z0-9]+", lower(var.name)))

  # kept for backwards-compatibility (no longer used as the actual Secret name)
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

# Suffix for final snapshot identifier (always computed and used)
resource "random_id" "final_snap_suffix" {
  byte_length = 4
}

# Compute a safe, length-bounded, letter-starting final snapshot prefix
locals {
  # choose caller prefix if set, else db_identifier
  _snap_prefix_base = coalesce(var.final_snapshot_identifier_prefix, local.db_identifier)
  # ensure starts with a letter (prepend 'a' if it does not)
  _snap_prefix_fixed = length(regexall("^[a-z]", lower(local._snap_prefix_base))) > 0 ? local._snap_prefix_base : "a${local._snap_prefix_base}"
  # trim leading/trailing hyphens
  _snap_prefix_trim = trim(local._snap_prefix_fixed, "-")
  # keep room for "-<8hex>" so stay under 255 chars (240 + 1 + 8 = 249)
  _snap_prefix_trunc = substr(local._snap_prefix_trim, 0, 240)
  # final id always present; provider uses it only when destroying with skip_final_snapshot=false
  final_snapshot_id = "${local._snap_prefix_trunc}-${random_id.final_snap_suffix.hex}"
}

# Password generator that avoids '/', '@', '"' and space (RDS rules)
resource "random_password" "master" {
  length           = 20
  special          = true
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

# Secrets Manager secret (username/password)
# Use caller-provided name if set; otherwise append a random suffix
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

  # Always set a valid final snapshot identifier; provider uses it only if skip_final_snapshot = false
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = local.final_snapshot_id

  parameter_group_name                = length(var.parameter_overrides) > 0 ? aws_db_parameter_group.this[0].name : null
  iam_database_authentication_enabled = var.iam_database_authentication_enabled

  apply_immediately = false

  tags = local.common_tags

  lifecycle {
    ignore_changes = [password]
  }
}

# Namespace
resource "kubernetes_namespace" "moodle" {
  metadata { name = "moodle" }
}

# Optional: gp3 storage class (EKS often sets a default; include if needed)
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }
  storage_provisioner = "ebs.csi.aws.com"
  parameters          = { type = "gp3" }
  volume_binding_mode = "WaitForFirstConsumer"
}


# PersistentVolumeClaim (10Gi to start)
resource "kubernetes_persistent_volume_claim" "moodle_pvc" {
  metadata {
    name      = "moodle-pvc"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "20Gi" } }
    storage_class_name = kubernetes_storage_class.gp3.metadata[0].name
  }
}

# DB password handling (simple path): set one value and reuse for RDS + k8s
# - Provide var.db_password and pass into your RDS module as master_password
# - Store same into a Kubernetes Secret to feed the app
resource "kubernetes_secret" "db" {
  metadata {
    name      = "moodle-db"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }
  data = {
    password = base64encode(coalesce(var.db_password, local.master_password_final))
  }
  type = "Opaque"
}



# Moodle Deployment (Bitnami image includes Apache web server)
resource "kubernetes_deployment" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    labels    = { app = "moodle" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "moodle" } }

    template {
      metadata { labels = { app = "moodle" } }

      spec {
        container {
          name  = "moodle"
          image = "bitnami/moodle:latest"

          port {
            container_port = 8080
          }

          # --- fixed: multi-line blocks; fixed: reference aws_db_instance.this.* ---
          env {
            name  = "MOODLE_DATABASE_TYPE"
            value = "pgsql"
          }
          env {
            name  = "MOODLE_DATABASE_HOST"
            value = aws_db_instance.this.address
          }
          env {
            name  = "MOODLE_DATABASE_PORT_NUMBER"
            value = tostring(aws_db_instance.this.port)
          }
          env {
            name  = "MOODLE_DATABASE_NAME"
            value = aws_db_instance.this.db_name
          }
          env {
            name  = "MOODLE_DATABASE_USER"
            value = "app_user" # match your RDS master_username
          }
          env {
            name = "MOODLE_DATABASE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "password"
              }
            }
          }

          # --- fixed: multi-line http_get blocks ---
          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 15
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          # --- fixed: multi-line volume_mount ---
          volume_mount {
            name       = "moodle-data"
            mount_path = "/bitnami/moodle"
          }
        }

        volume {
          name = "moodle-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.moodle_pvc.metadata[0].name
          }
        }
      }
    }
  }
}


# Service (cluster-internal; we’ll expose via Ingress/ALB below)
resource "kubernetes_service" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    labels    = { app = "moodle" }
  }
  spec {
    selector = { app = "moodle" }
    # --- fixed: no semicolons; multi-line block with one attribute per line ---
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}


# If you prefer a direct Service LoadBalancer (no Ingress), uncomment:
# resource "kubernetes_service" "moodle_lb" {
#   metadata {
#     name      = "moodle-lb"
#     namespace = kubernetes_namespace.moodle.metadata[0].name
#     annotations = {
#       "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
#     }
#   }
#   spec {
#     selector = { app = "moodle" }
#     port { name = "http"; port = 80; target_port = 8080 }
#     type = "LoadBalancer"
#   }
# }

resource "kubernetes_ingress_v1" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    }
  }
  spec {
    rule {
      host = var.moodle_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.moodle.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
    tls { hosts = [var.moodle_host] }
  }
}


# REPLACE your existing module "rds_postgresql" block with this:
module "rds_postgresql" {
  source = "./modules/rds-postgresql"

  # keep your existing name (or default from variables.tf)
  name = var.name

  # >>> use the actual IDs from your plan output <<<
  vpc_id             = "vpc-06d7e948b8ac6c1a0"
  private_subnet_ids = [
    "subnet-02b69e006ad0107d5",
    "subnet-0761c9eec76993d18",
  ]

  # optional: reuse your k8s secret input if you have it
  master_password = var.db_password

  # critical so destroy won't block
  deletion_protection              = false
  skip_final_snapshot              = true
  final_snapshot_identifier_prefix = null
}
