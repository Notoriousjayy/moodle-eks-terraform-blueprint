variable "name" {
  description = "Base name/prefix for resources"
  type        = string
  default     = "moodle"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster to deploy into"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where RDS and EKS live"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS (>= 2 for Multi-AZ)"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach RDS (e.g., EKS node SGs)"
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDRs allowed to reach RDS (use only if you cannot use SG IDs)"
  type        = list(string)
  default     = []
}

# DB settings (aligned with your plan)
variable "db_name" {
  type        = string
  default     = "appdb"
}
variable "db_username" {
  type        = string
  default     = "app_user"
}
variable "db_password" {
  description = "Master password for the RDS instance (also used in the k8s secret)"
  type        = string
  sensitive   = true
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

# Ingress / TLS
variable "moodle_host" {
  description = "Public hostname for Moodle (ALB Ingress)"
  type        = string
  default     = ""
}
variable "acm_certificate_arn" {
  description = "ACM cert ARN for TLS on the ALB"
  type        = string
  default     = ""
}
