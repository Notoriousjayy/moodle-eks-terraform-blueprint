terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.24"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- EKS-aware Kubernetes provider (no more http://localhost) ---
data "aws_eks_cluster" "this" {
  name = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# ---------------- RDS via MODULE ONLY (remove any root-level RDS resources) -------------
module "rds_postgresql" {
  source = "./modules/rds-postgresql"

  # Identity / networking
  name               = var.name
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids

  # Network access (prefer allowing EKS node SGs)
  allowed_security_group_ids = var.allowed_security_group_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks

  # DB config (kept consistent with your earlier plan)
  db_name         = var.db_name
  master_username = var.db_username
  master_password = var.db_password

  instance_class  = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  multi_az          = var.db_multi_az
  engine_version    = var.db_engine_version
  storage_type      = var.db_storage_type

  performance_insights_enabled = true
  storage_encrypted            = true
  publicly_accessible          = false
  backup_retention_period      = 7
  skip_final_snapshot          = true
}

# ----------------------- Kubernetes objects -----------------------
resource "kubernetes_namespace" "moodle" {
  metadata {
    name = "moodle"
  }
}

# StorageClass for EBS gp3
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  parameters = {
    type = "gp3"
  }
}

# PVC for Moodle persistent data
resource "kubernetes_persistent_volume_claim" "moodle_pvc" {
  metadata {
    name      = "moodle-pvc"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }
  spec {
    storage_class_name = kubernetes_storage_class.gp3.metadata[0].name
    access_modes       = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

# Secret that matches the RDS master password we passed to the module
resource "kubernetes_secret" "db" {
  metadata {
    name      = "moodle-db"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }
  type = "Opaque"
  data = {
    password = var.db_password
  }
}

# Moodle Deployment
resource "kubernetes_deployment" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    labels = { app = "moodle" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "moodle" } }

    template {
      metadata {
        labels = { app = "moodle" }
      }
      spec {
        container {
          name  = "moodle"
          image = "bitnami/moodle:latest"

          env { name = "MOODLE_DATABASE_TYPE"         value = "pgsql" }
          env { name = "MOODLE_DATABASE_HOST"         value = module.rds_postgresql.endpoint }
          env { name = "MOODLE_DATABASE_PORT_NUMBER"  value = "5432" }
          env { name = "MOODLE_DATABASE_NAME"         value = var.db_name }
          env { name = "MOODLE_DATABASE_USER"         value = var.db_username }
          env {
            name = "MOODLE_DATABASE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "password"
              }
            }
          }

          port { container_port = 8080 }

          liveness_probe {
            http_get { path = "/" port = "8080" }
            initial_delay_seconds = 60
            period_seconds        = 15
            timeout_seconds       = 1
            failure_threshold     = 3
          }

          readiness_probe {
            http_get { path = "/" port = "8080" }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 1
            failure_threshold     = 3
          }

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

# Cron to run Moodle's internal cron
resource "kubernetes_cron_job_v1" "moodle_cron" {
  metadata {
    name      = "moodle-cron"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }

  spec {
    schedule                      = "*/5 * * * *"
    concurrency_policy            = "Allow"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 1

    job_template {
      metadata { labels = { app = "moodle-cron" } }
      spec {
        backoff_limit = 6
        template {
          metadata { labels = { app = "moodle-cron" } }
          spec {
            restart_policy = "Never"
            container {
              name  = "cron"
              image = "bitnami/moodle:latest"
              command = ["bash","-lc","php -f /opt/bitnami/moodle/admin/cli/cron.php"]

              env { name = "MOODLE_DATABASE_TYPE"         value = "pgsql" }
              env { name = "MOODLE_DATABASE_HOST"         value = module.rds_postgresql.endpoint }
              env { name = "MOODLE_DATABASE_PORT_NUMBER"  value = "5432" }
              env { name = "MOODLE_DATABASE_NAME"         value = var.db_name }
              env { name = "MOODLE_DATABASE_USER"         value = var.db_username }
              env {
                name = "MOODLE_DATABASE_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.db.metadata[0].name
                    key  = "password"
                  }
                }
              }

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
  }
}

# ClusterIP service
resource "kubernetes_service" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    labels    = { app = "moodle" }
  }
  spec {
    selector = { app = "moodle" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ALB Ingress (optional TLS via ACM)
resource "kubernetes_ingress_v1" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{HTTP = 80}, {HTTPS = 443}])
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    }
  }

  spec {
    rule {
      host = var.moodle_host != "" ? var.moodle_host : null
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
    tls {
      hosts = var.moodle_host != "" ? [var.moodle_host] : [null]
    }
  }
}

# ----------------------- Helpful Outputs -----------------------
output "rds_endpoint" {
  value = module.rds_postgresql.endpoint
}

output "moodle_url" {
  value = var.moodle_host != "" ? "https://${var.moodle_host}" : "(set var.moodle_host to expose a hostname)"
}
