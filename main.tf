terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

provider "aws" {
  region = var.region
}

# ---------------- Root variables ----------------
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "num_azs" {
  description = "How many AZs to spread private subnets across (min 2 for Multi-AZ RDS)."
  type        = number
  default     = 2

  validation {
    condition     = var.num_azs >= 2
    error_message = "num_azs must be at least 2 for a Multi-AZ RDS deployment."
  }
}

# Optional: allow connectivity to RDS until EKS exists (e.g., from your office IP)
variable "allowed_cidr_blocks" {
  description = "CIDR blocks that may connect to Postgres 5432 (temporary dev/test access)."
  type        = list(string)
  default     = []
}

# Optional: once you have EKS/node SGs, put them here for least-privileged access
variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach Postgres 5432 (e.g., EKS cluster & node SGs)."
  type        = list(string)
  default     = []
}

# --------------- Build Network (VPC + Private Subnets) ---------------
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs              = slice(data.aws_availability_zones.available.names, 0, var.num_azs)
  # Create non-overlapping /19s within the VPC for private subnets
  private_subnet_cidrs = [for i in range(var.num_azs) : cidrsubnet(var.vpc_cidr, 3, i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "rds-postgres-vpc"
  }
}

# One private route table for all private subnets (no NAT/IGW needed for RDS)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "rds-private-rt"
  }
}

# Create private subnets across AZs
resource "aws_subnet" "private" {
  for_each                = { for idx, az in local.azs : az => idx }
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[each.value]
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name = "rds-private-${each.key}"
    # Helpful if you later add EKS:
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Associate all private subnets with the private route table
resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  route_table_id = aws_route_table.private.id
  subnet_id      = each.value.id
}

# ------------------- Call the RDS module -------------------
module "rds_postgresql" {
  source = "./modules/rds-postgresql"

  name               = "prod-app-postgres"
  vpc_id             = aws_vpc.this.id
  private_subnet_ids = [for s in aws_subnet.private : s.id]

  db_name         = "appdb"
  master_username = "app_user"
  # master_password optional (secret auto-created if omitted)

  engine_version            = "16.4"
  instance_class            = "db.m7g.large"
  allocated_storage         = 100
  max_allocated_storage     = 1000
  multi_az                  = true
  storage_encrypted         = true
  publicly_accessible       = false
  enable_performance_insights = true
  backup_retention_period     = 7
  deletion_protection         = true

  # Access control (pick one or both). While you don't have EKS yet, use allowed_cidr_blocks.
  allowed_security_group_ids = var.allowed_security_group_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks

  parameter_overrides = {
    "rds.force_ssl"              = "1"
    "log_min_duration_statement" = "500"
  }

  tags = {
    Environment = "prod"
    Service     = "my-app"
  }
}

# ------------------- Useful outputs -------------------
output "vpc_id" {
  value       = aws_vpc.this.id
  description = "Created VPC ID."
}

output "private_subnet_ids" {
  value       = [for s in aws_subnet.private : s.id]
  description = "Created private subnet IDs."
}

output "rds_endpoint" {
  value       = module.rds_postgresql.endpoint
  description = "PostgreSQL endpoint hostname."
}

output "rds_port" {
  value       = module.rds_postgresql.port
  description = "PostgreSQL port."
}
