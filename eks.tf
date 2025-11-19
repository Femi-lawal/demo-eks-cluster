module "eks" {
  source = "./modules/aws/eks/v1"

  region              = var.region
  cluster_name        = var.cluster_name
  private_subnets     = module.vpc.private_subnets
  public_subnets      = module.vpc.public_subnets
  vpc_id              = module.vpc.vpc_id
  eks_cluster_version = "1.31"

  managed_node_groups = {
    demo_group = {
      name           = "demo-node-group"
      desired_size   = 2
      min_size       = 1
      max_size       = 3
      instance_types = ["t3a.small"]
    }
  }

  additional_role_mappings = [
    {
      rolearn  = aws_iam_role.karpenter_controller_role.arn
      username = "system:serviceaccount:karpenter:karpenter"
      groups   = ["system:masters"]
    }
  ]

  additional_launch_template_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
