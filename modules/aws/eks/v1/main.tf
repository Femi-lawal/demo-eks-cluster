data "aws_partition" "current" {}

# Fetch current AWS account details
data "aws_caller_identity" "current" {}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

############################################################################################################
### EKS CLUSTER
############################################################################################################
resource "aws_eks_cluster" "main" {
  name                      = var.cluster_name
  role_arn                  = aws_iam_role.eks_cluster_role.arn
  enabled_cluster_log_types = ["audit", "api", "authenticator"]

  vpc_config {
    subnet_ids             = concat(var.private_subnets, var.public_subnets)
    security_group_ids     = [aws_security_group.eks_cluster_sg.id]
    endpoint_public_access = true

  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_encryption.arn
    }
    resources = ["secrets"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name
}

############################################################################################################
### KMS KEY
############################################################################################################
resource "aws_kms_key" "eks_encryption" {
  description         = "KMS key for EKS cluster encryption"
  policy              = data.aws_iam_policy_document.kms_key_policy.json
  enable_key_rotation = true
}

# alias
resource "aws_kms_alias" "eks_encryption" {
  name          = "alias/eks/${var.cluster_name}"
  target_key_id = aws_kms_key.eks_encryption.id
}

data "aws_iam_policy_document" "kms_key_policy" {
  statement {
    sid = "Key Administrators"
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:TagResource"
    ]
    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
        data.aws_caller_identity.current.arn
      ]
    }
    resources = ["*"]
  }

  statement {
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    resources = ["*"]
  }
}


resource "aws_iam_policy" "cluster_encryption" {
  name        = "${var.cluster_name}-encryption-policy"
  description = "IAM policy for EKS cluster encryption"
  policy      = data.aws_iam_policy_document.cluster_encryption.json
}

data "aws_iam_policy_document" "cluster_encryption" {
  statement {
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ListGrants",
      "kms:DescribeKey"
    ]
    resources = [aws_kms_key.eks_encryption.arn]
  }
}

# Granting the EKS Cluster role the ability to use the KMS key
resource "aws_iam_role_policy_attachment" "cluster_encryption" {
  policy_arn = aws_iam_policy.cluster_encryption.arn
  role       = aws_iam_role.eks_cluster_role.name
}

############################################################################################################
### MANAGED NODE GROUPS
############################################################################################################
resource "aws_eks_node_group" "main" {
  for_each = var.managed_node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = each.value.name
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = var.private_subnets

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  launch_template {
    id      = aws_launch_template.eks_node_group.id
    version = "$Default"
  }

  instance_types       = each.value.instance_types
  ami_type             = var.default_ami_type
  capacity_type        = var.default_capacity_type
  force_update_version = true
}

############################################################################################################
### LAUNCH TEMPLATE
############################################################################################################  
resource "aws_launch_template" "eks_node_group" {
  name_prefix = "${var.cluster_name}-eks-node-group-lt"
  description = "Launch template for ${var.cluster_name} EKS node group"

  vpc_security_group_ids = [aws_security_group.eks_nodes_sg.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda" # Adjusted to the common root device name for Linux AMIs

    ebs {
      volume_size           = 20    # Disk size specified here
      volume_type           = "gp3" # Example volume type, adjust as necessary
      delete_on_termination = true
    }
  }

  tags = {
    "Name"                                      = "${var.cluster_name}-eks-node-group"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  lifecycle {
    create_before_destroy = true
  }
}

############################################################################################################
### OIDC CONFIGURATION
############################################################################################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

############################################################################################################
### IAM ROLES
############################################################################################################
# EKS Cluster role
resource "aws_iam_role" "eks_cluster_role" {
  name               = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role_policy.json
}

data "aws_iam_policy_document" "eks_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

# EKS Cluster Policies
resource "aws_iam_role_policy_attachment" "eks_cloudwatch_policy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster_role.name
}

# Managed Node Group role
resource "aws_iam_instance_profile" "eks_node" {
  name = "eks_node"
  role = aws_iam_role.node_role.name
}

resource "aws_iam_role" "node_role" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Node Group Policies
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ebs_csi_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# VPC CNI Plugin Role
data "aws_iam_policy_document" "vpc_cni_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "vpc_cni_role" {
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_assume_role_policy.json
  name               = "${var.cluster_name}-vpc-cni-role"
}

resource "aws_iam_role_policy_attachment" "vpc_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni_role.name
}

############################################################################################################
### NETWORKING
############################################################################################################
# https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html
# https://aws.github.io/aws-eks-best-practices/security/docs/network/#:~:text=The%20minimum%20rules%20for%20the,that%20the%20kubelets%20listen%20on.
# Cluster Security group
resource "aws_security_group" "eks_cluster_sg" {
  name        = "${var.cluster_name}-eks-cluster-sg"
  description = "Security group for EKS cluster control plane communication with worker nodes"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-eks-cluster-sg"
  }
}

resource "aws_security_group_rule" "eks_cluster_ingress_nodes" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  description              = "Allow inbound traffic from the worker nodes on the Kubernetes API endpoint port"
}

resource "aws_security_group_rule" "eks_cluster_egress_kublet" {
  type                     = "egress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  description              = "Allow control plane to node egress for kubelet"
}

# Node Security group
resource "aws_security_group" "eks_nodes_sg" {
  name        = "${var.cluster_name}-eks-nodes-sg"
  description = "Security group for all nodes in the cluster"
  vpc_id      = var.vpc_id

  tags = {
    Name                                        = "${var.cluster_name}-eks-nodes-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Unneccessary because all outbound traffic from worker nodes is allowed by worker_node_egress_internet rule
# resource "aws_security_group_rule" "worker_node_to_control_plane_egress_https" {
#   type                     = "egress"
#   from_port                = 443
#   to_port                  = 443
#   protocol                 = "tcp"
#   security_group_id        = aws_security_group.eks_nodes_sg.id
#   source_security_group_id = aws_security_group.eks_cluster_sg.id
#   description              = "Allow worked node to control plane/Kubernetes API egress for HTTPS"
# }

resource "aws_security_group_rule" "worker_node_to_worker_node_ingress_coredns_tcp" {
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_nodes_sg.id
  self              = true
  description       = "Allow workers nodes to communicate with each other for coredns TCP"
}

resource "aws_security_group_rule" "worker_node_to_worker_node_ingress_coredns_udp" {
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  security_group_id = aws_security_group.eks_nodes_sg.id
  self              = true
  description       = "Allow workers nodes to communicate with each other for coredns UDP"
}

resource "aws_security_group_rule" "worker_node_ingress_kublet" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  description              = "Allow control plane to node ingress for kubelet"
}

resource "aws_security_group_rule" "worker_node_to_worker_node_ingress_ephemeral" {
  type              = "ingress"
  from_port         = 1025
  to_port           = 65535
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.eks_nodes_sg.id
  description       = "Allow workers nodes to communicate with each other on ephemeral ports"
}

resource "aws_security_group_rule" "worker_node_egress_internet" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_nodes_sg.id
  description       = "Allow outbound internet access"
}

############################################################################################################
### CLUSTER ROLE BASE ACCESS CONTROL
############################################################################################################
# Define IAM Role for EKS Administrators
resource "aws_iam_role" "eks_admins_role" {
  name = "${var.cluster_name}-eks-admins-role"

  assume_role_policy = data.aws_iam_policy_document.eks_admins_assume_role_policy_doc.json
}

# IAM Policy Document for assuming the eks-admins role
data "aws_iam_policy_document" "eks_admins_assume_role_policy_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    effect = "Allow"
  }
}

# Define IAM Policy for administrative actions on EKS
data "aws_iam_policy_document" "eks_admin_policy_doc" {
  statement {
    actions   = ["eks:*", "ec2:Describe*", "iam:ListRoles", "iam:ListRolePolicies", "iam:GetRole"]
    resources = ["*"]
  }
}

# Create IAM Policy based on the above document
resource "aws_iam_policy" "eks_admin_policy" {
  name   = "${var.cluster_name}-eks-admin-policy"
  policy = data.aws_iam_policy_document.eks_admin_policy_doc.json
}

# Attach IAM Policy to the EKS Administrators Role
resource "aws_iam_role_policy_attachment" "eks_admin_role_policy_attach" {
  role       = aws_iam_role.eks_admins_role.name
  policy_arn = aws_iam_policy.eks_admin_policy.arn
}

# Update the aws-auth ConfigMap to include the IAM group
resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([
      {
        rolearn  = aws_iam_role.eks_admins_role.arn
        username = aws_iam_role.eks_admins_role.name
        groups   = ["system:masters"]
      }
    ])
    mapUsers = yamlencode([
      {
        userarn  = data.aws_caller_identity.current.arn
        username = split("/", data.aws_caller_identity.current.arn)[1]
        groups   = ["system:masters"]
      }
    ])
  }

}


############################################################################################################
# PLUGINS
############################################################################################################
data "aws_eks_addon_version" "main" {
  for_each = toset(var.cluster_addons)

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.main.version
}

resource "aws_eks_addon" "main" {
  for_each = toset(var.cluster_addons)

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.main[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on = [
    aws_eks_node_group.main
  ]
}
