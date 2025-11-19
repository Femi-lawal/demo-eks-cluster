output "karpenter_controller_role_arn" {
  description = "The ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller_role.arn
}

output "aws_region" {
  description = "The AWS region where the EKS cluster is deployed"
  value       = var.region
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = var.cluster_name
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster"
  value       = module.eks.cluster_endpoint
}

output "node_instance_role_arn" {
  description = "The ARN of the node instance role"
  value       = module.eks.node_instance_role_arn
}
