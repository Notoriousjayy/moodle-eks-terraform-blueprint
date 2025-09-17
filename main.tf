# main.tf — drop-in replacement
# Provisions a NEW EKS cluster (random, prefixed name) and a NEW VPC when no IDs are supplied.
# If var.vpc_id and var.private_subnet_ids are provided, those are used instead.

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
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.9.0, < 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

# Optional override for EKS API access CIDRs; defaults to your current /32 if empty
variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS public API. Leave empty to fall back to your current /32."
  type        = list(string)
  default     = []
}

provider "aws" {
  region = var.region
}

# Who's running this? (so we can grant them admin in the cluster)
data "aws_caller_identity" "current" {}

# Discover available AZs (for VPC creation when IDs are not provided)
data "aws_availability_zones" "available" {
  state = "available"
}

# Your current public IP for scoping EKS API access (e.g., "203.0.113.5")
data "http" "caller_ip" {
  url = "https://checkip.amazonaws.com/"
}

# Suffix for cluster name
resource "random_id" "eks_suffix" {
  byte_length = 2 # 4 hex chars
}

# ---------------- VPC (auto-create if no IDs given) ----------------
locals {
  # If BOTH vpc_id and private_subnet_ids are set, use existing; else, create a new VPC.
  use_existing_vpc = try(var.vpc_id != null && var.vpc_id != "" && length(var.private_subnet_ids) > 0, false)
}

module "vpc" {
  count   = local.use_existing_vpc ? 0 : 1
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.name}-vpc"
  cidr = "10.0.0.0/16"

  # Take the first two AZs for simplicity
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project = var.name
  }
}

locals {
  cluster_name = "${var.name}-eks-${random_id.eks_suffix.hex}" # e.g., moodle-eks-a1b2

  vpc_id_effective             = local.use_existing_vpc ? var.vpc_id : module.vpc[0].vpc_id
  private_subnet_ids_effective = local.use_existing_vpc ? var.private_subnet_ids : module.vpc[0].private_subnets

  # Caller IP /32 for EKS public API scoping
  caller_ip   = chomp(data.http.caller_ip.response_body)
  caller_cidr = "${local.caller_ip}/32"

  # IMPORTANT: Always include the "eks_nodes" key so for_each KEYS are known at plan.
  rds_allowed_sg_map = merge(
    { for i, sg in try(var.allowed_security_group_ids, []) : "user_${i}" => sg },
    { "eks_nodes" = module.eks.node_security_group_id }
  )
}

# Minimal custom Launch Template for the node group (lets us control LT ownership/tags)
# NOTE: Do not set security groups / user_data / AMI here; EKS will handle those.
resource "aws_launch_template" "mng" {
  name_prefix            = "${var.name}-mng-"
  update_default_version = true

  # Give org-required tags to Instances/Volumes/NICs at launch (common SCP pattern).
  tag_specifications {
    resource_type = "instance"
    tags = {
      Project = var.name
    }
  }
  tag_specifications {
    resource_type = "volume"
    tags = {
      Project = var.name
    }
  }
  tag_specifications {
    resource_type = "network-interface"
    tags = {
      Project = var.name
    }
  }

  tags = {
    Project = var.name
  }
}

# ---------------- EKS (managed via official module) ----------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.30"

  vpc_id     = local.vpc_id_effective
  subnet_ids = local.private_subnet_ids_effective

  enable_irsa = true

  # Add the Terraform caller as cluster-admin via EKS Access Entries (replaces aws-auth args)
  enable_cluster_creator_admin_permissions = true

  # Make the API reachable to Terraform by enabling public access scoped to your IP or overrides
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = length(var.api_allowed_cidrs) > 0 ? var.api_allowed_cidrs : [local.caller_cidr]

  # One simple managed node group (uses our custom LT to avoid org denial on EKS-created LT)
  eks_managed_node_groups = {
    default = {
      instance_types             = ["t3.medium"]
      min_size                   = 1
      max_size                   = 3
      desired_size               = 1
      subnet_ids                 = local.private_subnet_ids_effective
      use_custom_launch_template = false
      launch_template_id         = aws_launch_template.mng.id
      launch_template_version    = "$Latest"
      ami_type                   = "AL2_x86_64" # let EKS pick the optimized AMI
    }
  }

  # Core add-ons (versions default to latest compatible)
  cluster_addons = {
    coredns            = {}
    kube-proxy         = {}
    vpc-cni            = {}
    aws-ebs-csi-driver = {}
  }

  tags = {
    Project = var.name
  }

  depends_on = [aws_launch_template.mng]
}

# --------- Providers (exec auth for fresh tokens) ----------
# NOTE: Requires awscli available in the environment where Terraform runs.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

# Grace period to ensure API is reachable from your IP before Helm/K8s ops
resource "time_sleep" "wait_for_api" {
  depends_on      = [module.eks]
  create_duration = "180s" # was 60s
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.13"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # turn on ALB Controller
  enable_aws_load_balancer_controller = true

  # optional chart settings; vpcId helps when auto-detection fails
  aws_load_balancer_controller = {
    set = [
      { name = "vpcId", value = local.vpc_id_effective },
      # { name = "enableServiceMutatorWebhook", value = "false" } # optional behavior tweak
    ]
  }

  tags = { Project = var.name }

  # Ensure this module uses our configured providers and waits for API reachability
  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  depends_on = [time_sleep.wait_for_api]
}

# ----- Robust readiness gate: proceed only after API + core addons are up -----
resource "null_resource" "wait_for_cluster_ready" {
  depends_on = [
    module.eks,
    module.eks_blueprints_addons,
    time_sleep.wait_for_api
  ]

  triggers = {
    cluster_name = module.eks.cluster_name
    endpoint     = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<EOT
set -eu
aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}

# API health (short request timeout so we fail fast if unreachable)
kubectl --request-timeout=15s get --raw=/readyz >/dev/null

# Core addon readiness
kubectl -n kube-system rollout status deploy/coredns --timeout=5m

# EBS CSI (managed addon) readiness — only wait if the objects already exist
if kubectl -n kube-system get deploy ebs-csi-controller >/dev/null 2>&1; then
  kubectl -n kube-system rollout status deploy/ebs-csi-controller --timeout=5m
fi
if kubectl -n kube-system get daemonset ebs-csi-node >/dev/null 2>&1; then
  kubectl -n kube-system rollout status daemonset/ebs-csi-node --timeout=5m
fi
EOT
  }
}

# ---------------- RDS via MODULE ONLY ----------------
module "rds_postgresql" {
  source = "./modules/rds-postgresql"

  # Identity / networking
  name               = var.name
  vpc_id             = local.vpc_id_effective
  private_subnet_ids = local.private_subnet_ids_effective

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

  tags = {
    Project = var.name
  }
}

# ---------------- Kubernetes objects ----------------
resource "kubernetes_namespace" "moodle" {
  metadata {
    name = "moodle"
  }
  depends_on = [null_resource.wait_for_cluster_ready]
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

  depends_on = [null_resource.wait_for_cluster_ready]
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

  depends_on = [null_resource.wait_for_cluster_ready]
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

  depends_on = [null_resource.wait_for_cluster_ready]
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
            name  = "MOODLE_DATABASE_PASSWORD"
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

  depends_on = [null_resource.wait_for_cluster_ready]
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

  depends_on = [null_resource.wait_for_cluster_ready]
}

# ALB Ingress (requires AWS Load Balancer Controller installed in the cluster)
resource "kubernetes_ingress_v1" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    annotations = merge(
      {
        "kubernetes.io/ingress.class"           = "alb"
        "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
        "alb.ingress.kubernetes.io/target-type" = "ip"
      },
      var.acm_certificate_arn != "" ? {
        "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
        "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
        "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      } : {
        "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ HTTP = 80 }])
      }
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

  # Ensure ALB Controller is present before creating the Ingress
  depends_on = [module.eks_blueprints_addons]
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
