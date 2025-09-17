output "db_instance_id" {
  value       = aws_db_instance.this.id
  description = "DB instance identifier."
}

output "endpoint" {
  value       = aws_db_instance.this.address
  description = "DB endpoint hostname."
}

output "port" {
  value       = aws_db_instance.this.port
  description = "DB port."
}

output "db_name" {
  value       = aws_db_instance.this.db_name
  description = "Initial DB name."
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "RDS security group ID."
}

output "subnet_group_name" {
  value       = aws_db_subnet_group.this.name
  description = "DB subnet group name."
}

output "master_secret_arn" {
  value       = try(aws_secretsmanager_secret.master[0].arn, null)
  description = "ARN of the Secrets Manager secret (username/password)."
}

output "parameter_group_name" {
  value       = try(aws_db_parameter_group.this[0].name, null)
  description = "DB parameter group name when created."
}
