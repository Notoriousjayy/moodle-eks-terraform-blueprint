resource "kubernetes_cron_job_v1" "moodle_cron" {
  metadata {
    name      = "moodle-cron"
    namespace = kubernetes_namespace.moodle.metadata[0].name
  }

  spec {
    schedule = "*/5 * * * *"

    job_template {
      metadata {
        labels = { app = "moodle-cron" }
      }
      spec {
        template {
          metadata {
            labels = { app = "moodle-cron" }
          }
          spec {
            restart_policy = "Never"

            container {
              name  = "cron"
              image = "bitnami/moodle:latest"

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
                value = "app_user"
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

              command = ["bash", "-lc", "php -f /opt/bitnami/moodle/admin/cli/cron.php"]

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
