variable "name" {
  type    = string
  default = "moodle"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "region" {
  type    = string
  default = null
}

variable "vpc_cidr" {
  type    = string
  default = null
}

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "master_username" {
  type    = string
  default = "app_user"
}

variable "master_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "secret_name" {
  type    = string
  default = null
}

variable "final_snapshot_identifier_prefix" {
  type    = string
  default = null
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "allocated_storage" {
  type    = number
  default = 100
}

variable "max_allocated_storage" {
  type    = number
  default = 0
}

variable "storage_encrypted" {
  type    = bool
  default = true
}

variable "kms_key_id" {
  type    = string
  default = null
}

variable "storage_type" {
  type    = string
  default = "gp3"
}

variable "iops" {
  type    = number
  default = null
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "publicly_accessible" {
  type    = bool
  default = false
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "backup_window" {
  type    = string
  default = null
}

variable "maintenance_window" {
  type    = string
  default = null
}

variable "auto_minor_version_upgrade" {
  type    = bool
  default = true
}

variable "enable_performance_insights" {
  type    = bool
  default = true
}

variable "performance_insights_kms_key_id" {
  type    = string
  default = null
}

variable "iam_database_authentication_enabled" {
  type    = bool
  default = false
}

variable "parameter_overrides" {
  type    = map(string)
  default = {}
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "private_subnet_ids" {
  type    = list(string)
  default = []
}

variable "allowed_security_group_ids" {
  type    = list(string)
  default = []
}

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = []
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "moodle_host" {
  type    = string
  default = ""
}

variable "db_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "create_master_secret" {
  type    = bool
  default = true
}
