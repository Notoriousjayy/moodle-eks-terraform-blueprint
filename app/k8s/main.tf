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
  provisioner = "ebs.csi.aws.com"
  parameters  = { type = "gp3" }
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
    password = base64encode(var.db_password)
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

          port { container_port = 8080 }

          env { name = "MOODLE_DATABASE_TYPE"        value = "pgsql" }
          env { name = "MOODLE_DATABASE_HOST"        value = module.rds_postgresql.endpoint }
          env { name = "MOODLE_DATABASE_PORT_NUMBER" value = tostring(module.rds_postgresql.port) }
          env { name = "MOODLE_DATABASE_NAME"        value = module.rds_postgresql.db_name }
          env { name = "MOODLE_DATABASE_USER"        value = "app_user" } # match your RDS master_username

          env {
            name = "MOODLE_DATABASE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "password"
              }
            }
          }

          # Health checks
          liveness_probe {
            http_get { path = "/" port = 8080 }
            initial_delay_seconds = 60
            period_seconds        = 15
          }
          readiness_probe {
            http_get { path = "/" port = 8080 }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          volume_mount {
            name       = "moodle-data"
            mount_path = "/bitnami/moodle"   # persistent uploads
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
    port { name = "http"; port = 80; target_port = 8080 }
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

# Ingress (ALB) with TLS via ACM
variable "acm_certificate_arn" { type = string }
variable "moodle_host"         { type = string } # e.g., "lms.example.com"

resource "kubernetes_ingress_v1" "moodle" {
  metadata {
    name      = "moodle"
    namespace = kubernetes_namespace.moodle.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                  = "alb"
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/certificate-arn"    = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"       = "443"
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
