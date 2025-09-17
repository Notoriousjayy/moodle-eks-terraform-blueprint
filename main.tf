# main.tf — drop-in replacement
# Provisions a NEW EKS cluster with a random, prefixed name and uses it for Kubernetes resources.
# (All multi-arg blocks expanded to avoid single-line block errors.)

terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.95.0, < 6.0.0"
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

# Who's running this? (so we can grant them admin in the cluster)
data "aws_caller_identity" "current" {}

# Suffix for cluster name
resource "random_id" "eks_suffix" {
  byte_length = 2 # 4 hex chars
}

locals {
  cluster_name = "${var.name}-eks-${random_id.eks_suffix.hex}" # e.g., moodle-eks-a1b2

  # IMPORTANT: Always include the "eks_nodes" key so for_each KEYS are known at plan.
  # Values may still be unknown at plan, which is fine.
  rds_allowed_sg_map = merge(
    { for i, sg in try(var.allowed_security_group_ids, []) : "user_${i}" => sg },
    { "eks_nodes" = module.eks.node_security_group_id }
  )
}

# ---------------- EKS (managed via official module) ----------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.30"

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  enable_irsa = true

  # Add the Terraform caller as cluster-admin via EKS Access Entries (replaces aws-auth args)
  enable_cluster_creator_admin_permissions = true

  # One simple managed node group
  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      subnet_ids     = var.private_subnet_ids
    }
  }

  # Core add-ons (versions default to latest compatible)
  cluster_addons = {
    coredns            = {}
    kube-proxy         = {}
    vpc-cni            = {}
    aws-ebs-csi-driver = {}
  }
}

# Kubernetes auth for provider
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# ---------------- RDS via MODULE ONLY ----------------
module "rds_postgresql" {
  source = "./modules/rds-postgresql"

  # Identity / networking
  name               = var.name
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids

  # Network access: include EKS node SG automatically (map with stable keys)
  allowed_security_group_ids = local.rds_allowed_sg_map
  allowed_cidr_blocks        = var.allowed_cidr_blocks

  # DB config
  db_name         = var.db_name
  master_username = var.db_username
  master_password = var.db_password

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  multi_az          = var.db_multi_az
  engine_version    = var.db_engine_version
  storage_type      = var.db_storage_type

  enable_performance_insights = true
  storage_encrypted           = true
  publicly_accessible         = false
  backup_retention_period     = 7
  skip_final_snapshot         = true
}

# ---------------- Kubernetes objects ----------------
resource "kubernetes_namespace" "moodle" {
  metadata {
    name = "moodle"
  }
}

# EBS gp3 StorageClass (non-default)
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

# DB password Secret (provider expects base64-encoded `data`)
resource "kubernetes_secret" "db" {
  metadata {
    name      = "moodle-db"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }
  type = "Opaque"
  data = {
    password = base64encode(var.db_password)
  }
}

# Moodle Deployment (Bitnami image)
resource "kubernetes_deployment" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    labels = {
      app = "moodle"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "moodle"
      }
    }

    template {
      metadata {
        labels = {
          app = "moodle"
        }
      }

      spec {
        container {
          name  = "moodle"
          image = "bitnami/moodle:latest"

          port {
            container_port = 8080
          }

          env {
            name  = "MOODLE_DATABASE_TYPE"
            value = "pgsql"
          }
          env {
            name  = "MOODLE_DATABASE_HOST"
            value = module.rds_postgresql.endpoint
          }
          env {
            name  = "MOODLE_DATABASE_PORT_NUMBER"
            value = "5432"
          }
          env {
            name  = "MOODLE_DATABASE_NAME"
            value = var.db_name
          }
          env {
            name  = "MOODLE_DATABASE_USER"
            value = var.db_username
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

# ClusterIP service (fronted by ALB Ingress if controller installed)
resource "kubernetes_service" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    labels = {
      app = "moodle"
    }
  }
  spec {
    selector = {
      app = "moodle"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ALB Ingress (requires AWS Load Balancer Controller installed in the cluster)
resource "kubernetes_ingress_v1" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    annotations = merge(
      {
        "kubernetes.io/ingress.class"            = "alb"
        "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"  = "ip"
        "alb.ingress.kubernetes.io/ssl-redirect" = "443"
        "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      },
      var.acm_certificate_arn != "" ? {
        "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
      } : {}
    )
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
              port {
                number = 80
              }
            }
          }
        }
      }
    }

    dynamic "tls" {
      for_each = var.moodle_host != "" ? [1] : []
      content {
        hosts = [var.moodle_host]
      }
    }
  }
}

# ---------------- Helpful outputs ----------------
output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "rds_endpoint" {
  value = module.rds_postgresql.endpoint
}

output "moodle_url" {
  value = var.moodle_host != "" ? "https://${var.moodle_host}" : "(set var.moodle_host to expose a hostname)"
}
