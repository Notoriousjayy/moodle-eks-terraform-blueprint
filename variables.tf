variable "name" {
  description = "Project/base name used for resources."
  type        = string
  default     = "moodle"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

# --- Networking strategy ---
variable "create_vpc" {
  description = "If true, create a new VPC + subnets; otherwise use provided IDs."
  type        = bool
  default     = true
}

# If create_vpc = true, these define the new VPC
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "azs" {
  description = "Two or more AZs for private/public subnets."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.101.0/24", "10.0.102.0/24"]
}
variable "enable_nat_gateway" {
  type    = bool
  default = true
}
variable "single_nat_gateway" {
  type    = bool
  default = true
}

# If create_vpc = false, supply existing IDs below
variable "vpc_id" {
  description = "Existing VPC ID when create_vpc = false."
  type        = string
  default     = null
}
variable "private_subnet_ids" {
  description = "Existing private subnet IDs when create_vpc = false."
  type        = list(string)
  default     = []
}

# --- Security group allowlists for RDS (extras; EKS node SG is auto-added) ---
variable "allowed_security_group_ids" {
  description = "Optional additional SG IDs allowed to reach the DB (e.g., bastion)."
  type        = list(string)
  default     = []
}
variable "allowed_cidr_blocks" {
  description = "Optional CIDR blocks for DB ingress (leave empty for cluster-only)."
  type        = list(string)
  default     = []
}

# --- EKS ---
variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}
variable "node_instance_types" {
  type    = list(string)
  default = ["t2.medium"] # changed from ["t3.medium"] to satisfy SCP
}
variable "node_desired_size" {
  type    = number
  default = 1
}
variable "node_min_size" {
  type    = number
  default = 1
}
variable "node_max_size" {
  type    = number
  default = 3
}

# --- RDS PostgreSQL ---
variable "db_name" {
  type    = string
  default = "moodle"
}
variable "db_username" {
  type    = string
  default = "moodleuser"
}
variable "db_password" {
  type        = string
  sensitive   = true
  description = "8–128 chars; avoid / @ \" or spaces."
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}
variable "db_allocated_storage" {
  type    = number
  default = 100
}
variable "db_multi_az" {
  type    = bool
  default = true
}
variable "db_engine_version" {
  type    = string
  default = "16.4"
}
variable "db_storage_type" {
  type    = string
  default = "gp3"
}

# Optional TLS + host for the ALB Ingress
variable "acm_certificate_arn" {
  description = "ACM cert ARN for HTTPS on the ALB Ingress. Leave empty to run HTTP-only."
  type        = string
  default     = ""
}

variable "moodle_host" {
  description = "DNS host for the Ingress (e.g., lms.example.com). Leave empty to use ALB DNS."
  type        = string
  default     = ""
}
