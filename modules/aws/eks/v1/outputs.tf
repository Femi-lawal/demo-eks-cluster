output "cluster_id" {
  description = "The EKS cluster ID"
  value       = aws_eks_cluster.main.id
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster API"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "The security group ID of the EKS cluster"
  value       = aws_eks_cluster.main.vpc_config[0].security_group_ids
}

output "node_group_role_arn" {
  description = "The ARN of the IAM role used by the node group"
  value       = aws_iam_role.node_role.arn
}

output "cluster_admins_arn" {
  description = "The ARN of the role for EKS cluster admins"
  value       = aws_iam_role.eks_admins_role.arn
}
