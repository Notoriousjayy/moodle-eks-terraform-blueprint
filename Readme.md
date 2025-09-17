# moodle-eks-terraform-blueprint

Automated, reproducible Moodle on AWS—provisioned with Terraform and deployed to Amazon EKS, backed by Amazon RDS for PostgreSQL, with optional plugin auto-install.&#x20;

![Architecture](docs/architecture.png)
*EKS + ALB (via controller/IRSA) fronts Bitnami Moodle; persistent storage via PVC (EBS or EFS); RDS PostgreSQL in private subnets; DNS CNAME to ALB.*&#x20;

---

## What you get

* **IaC**: Terraform builds EKS (control plane + node group), VPC/subnets, RDS (PostgreSQL), security groups, and Kubernetes resources. RDS is **not publicly accessible** and only allows port **5432** from EKS.&#x20;
* **App deploy**: Bitnami **Moodle** container configured by env vars and exposed by a type **LoadBalancer** Service (ALB).&#x20;
* **Storage**: PVC for Moodle data. Start with **EBS (gp2/gp3)**; use **EFS (CSI)** for multi-pod/HA.&#x20;
* **Plugins**: Optional automation via custom image or init/post-start hook plus `admin/cli/upgrade.php --non-interactive`.&#x20;

---

## Repo layout (suggested)

```
/infra/terraform/        # VPC, EKS, IRSA, RDS, security groups, k8s providers
/app/k8s/                # k8s Deployment/Service/PVC (if not using Helm)
/plugins/                # Dockerfile or init scripts to auto-install plugins
/environments/           # dev/stage/prod *.tfvars
/docs/architecture.png   # <- place your diagram here
```

---

## Prerequisites

* AWS account + credentials configured
* Terraform
* kubectl and AWS CLI (for kubeconfig)
* (Optional) Helm for ALB Controller or chart-based deploys

> The EKS cluster should enable **IAM OIDC** for IRSA; the **AWS Load Balancer Controller** can then manage the external ALB.&#x20;

---

## Quick start

1. **Provision infrastructure**

```bash
cd infra/terraform
terraform init
terraform apply -var-file=../environments/dev.tfvars
```

* Creates EKS (private subnets), RDS PostgreSQL (in a DB subnet group), and SG rules allowing EKS→RDS on 5432. RDS is private.&#x20;

2. **Configure kubectl**

```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

3. **(Recommended) Install AWS Load Balancer Controller** using IRSA, then expose Moodle via a LoadBalancer Service or Ingress.&#x20;

4. **Deploy Moodle**

If using Terraform’s Kubernetes provider:

```hcl
# app/k8s/main.tf (excerpt)
resource "kubernetes_deployment" "moodle" {
  metadata { name = "moodle" }
  spec {
    replicas = 1
    selector { match_labels = { app = "moodle" } }
    template {
      metadata { labels = { app = "moodle" } }
      spec {
        container {
          name  = "moodle"
          image = "bitnami/moodle:latest"
          env { name = "MOODLE_DATABASE_TYPE"        value = "pgsql" }
          env { name = "MOODLE_DATABASE_HOST"        value = aws_db_instance.moodle.address }
          env { name = "MOODLE_DATABASE_PORT_NUMBER" value = "5432" }
          env { name = "MOODLE_DATABASE_NAME"        value = "moodle" }
          env { name = "MOODLE_DATABASE_USER"        value = "moodleuser" }
          env { name = "MOODLE_DATABASE_PASSWORD"    value = var.db_password }
          ports { container_port = 8080 }
          volume_mount { name = "moodle-data" mount_path = "/bitnami/moodle" }
        }
        volume {
          name = "moodle-data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim.moodle_pvc.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service" "moodle_lb" {
  metadata { name = "moodle" }
  spec {
    type = "LoadBalancer"
    port { port = 80  target_port = 8080 }
    selector = { app = "moodle" }
  }
}
```

* The Bitnami image autoconfigures Moodle at first boot using these env vars and serves on **8080**; the Service exposes **80**.&#x20;

5. **Persistent storage**

```hcl
resource "kubernetes_persistent_volume_claim" "moodle_pvc" {
  metadata { name = "moodle-pvc" }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "10Gi" } }
    storage_class_name = "gp3" # or "efs-sc" if using EFS CSI
  }
}
```

* Use **EBS** for single-pod; switch to **EFS CSI** for shared, multi-pod access.&#x20;

6. **Get the URL & set DNS**

* After apply, note the Service’s external hostname and create a **CNAME** in your DNS to the ALB DNS name.&#x20;

---

## Plugin automation (optional)

Two supported approaches:

* **Custom image**: bake plugin code into the image during build (e.g., fetch ZIPs and unzip into `mod/` or `blocks/`).&#x20;
* **Init/Post-start hook**: download plugins to the PVC, then run Moodle’s CLI upgrade to register them:

```bash
php admin/cli/upgrade.php --non-interactive --allow-unstable
```

This makes plugins available on first start without manual UI steps. Ensure idempotency so re-applies don’t duplicate work.&#x20;

---

## Security notes

* RDS is private; ingress to **5432** is restricted to EKS (tighten to SG-to-SG where possible).&#x20;
* Nodes run in private subnets; only the ALB is public.&#x20;

---

## Upgrades

Use a pinned Bitnami tag or periodically update to the latest (Moodle releases are frequent). Roll your Deployment to pick up the new image.&#x20;

---

## Outputs (typical)

* `rds_endpoint` – PostgreSQL host for Moodle
* `moodle_lb_hostname` – external URL of the Moodle Service

> The initial web flow will finalize setup (admin user, etc.) if not preseeded via env. Verify DB connectivity and that your plugins appear under **Site administration → Plugins → Plugins overview**.&#x20;

---

## Cleanup

```bash
terraform destroy
```

Destroys EKS, RDS, and Kubernetes resources created by Terraform. (Be careful—this deletes data unless you’ve snapshot/backed up RDS and persisted Moodle data elsewhere.)&#x20;

---

## License

MIT

---

### References

* Architecture & approach, components, and flows.&#x20;
* EKS + RDS setup, SG rule examples, private RDS.&#x20;
* Moodle Deployment, env vars, ports, Service type.&#x20;
* Storage options (EBS vs EFS CSI).&#x20;
* Plugin automation and CLI upgrade.&#x20;

---