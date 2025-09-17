variable "name" {
  description = "Logical name/prefix for DB resources (used in identifiers and tags)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID hosting the DB subnets and EKS."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the DB subnet group (min 2 for Multi-AZ)."
  type        = list(string)
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "master_username" {
  description = "Master username. Avoid 'postgres'."
  type        = string
  default     = "app_user"
}

variable "master_password" {
  description = "Optional explicit password. If null, a random one is generated and stored in Secrets Manager."
  type        = string
  default     = null
  sensitive   = true

  # RDS requires printable ASCII except '/', '@', '\"', and space.
  validation {
    condition = var.master_password == null || (
      length(var.master_password) >= 8 &&
      length(var.master_password) <= 128 &&
      length(regexall("[/@\"\\s]", var.master_password)) == 0
    )
    error_message = "master_password must be 8–128 chars and must NOT contain '/', '@', '\"', or spaces."
  }
}

variable "engine_version" {
  description = "PostgreSQL engine version. Use full semantic version."
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "allocated_storage" {
  description = "Initial storage (GiB)."
  type        = number
  default     = 100
}

variable "max_allocated_storage" {
  description = "Autoscaling storage max (GiB). Set 0 to disable."
  type        = number
  default     = 0
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment."
  type        = bool
  default     = true
}

variable "storage_encrypted" {
  description = "Enable storage encryption."
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "KMS key for storage encryption (optional)."
  type        = string
  default     = null
}

variable "publicly_accessible" {
  description = "Whether the DB has a public IP. Keep false for EKS-internal access."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days to retain automatic backups."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Preferred backup window, e.g. '03:00-04:00'."
  type        = string
  default     = null
}

variable "maintenance_window" {
  description = "Preferred maintenance window, e.g. 'Sun:04:00-Sun:05:00'."
  type        = string
  default     = null
}

variable "auto_minor_version_upgrade" {
  description = "Auto minor version upgrades."
  type        = bool
  default     = true
}

variable "enable_performance_insights" {
  description = "Enable Performance Insights."
  type        = bool
  default     = true
}

variable "performance_insights_kms_key_id" {
  description = "KMS key for Performance Insights (optional)."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Protect the instance from deletion."
  type        = bool
  default     = true
}

variable "parameter_overrides" {
  description = "DB parameter key/value map (e.g., { \"rds.force_ssl\" = \"1\" })."
  type        = map(string)
  default     = {}
}

variable "iam_database_authentication_enabled" {
  description = "Enable IAM token-based auth (PostgreSQL)."
  type        = bool
  default     = false
}

variable "allowed_security_group_ids" {
  description = "Security group IDs that may reach the DB on 5432 (e.g., EKS node/cluster SGs)."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the DB on 5432. Prefer SGs over CIDRs."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to created resources."
  type        = map(string)
  default     = {}
}

variable "create_master_secret" {
  description = "Create an AWS Secrets Manager secret containing master credentials."
  type        = bool
  default     = true
}

variable "secret_name" {
  description = "Optional custom name for the created secret."
  type        = string
  default     = null
}

variable "storage_type" {
  description = "Storage type: gp3 recommended."
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "Provisioned IOPS (only for io1/io2/gp3)."
  type        = number
  default     = null
}
