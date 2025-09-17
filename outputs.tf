output "vpc_id" {
  value       = local.vpc_id_effective
  description = "VPC ID in use."
}

output "private_subnet_ids" {
  value       = local.private_subnet_ids_effective
  description = "Private subnet IDs used by EKS/RDS."
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "rds_security_group_id" {
  value = try(module.rds_postgresql.security_group_id, null)
}
