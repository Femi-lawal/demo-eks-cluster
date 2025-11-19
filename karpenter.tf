############################################################################################################
### KARPENTER
############################################################################################################

# IAM Role for Karpenter Controller
data "aws_iam_policy_document" "karpenter_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "karpenter_controller_role" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role_policy.json
}

# Karpenter Controller Policy
data "aws_iam_policy_document" "karpenter_controller_policy" {
  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]
    resources = [
      "arn:aws:ec2:${var.region}::image/*",
      "arn:aws:ec2:${var.region}::snapshot/*",
      "arn:aws:ec2:${var.region}:*:security-group/*",
      "arn:aws:ec2:${var.region}:*:subnet/*",
      "arn:aws:ec2:${var.region}:*:launch-template/*"
    ]
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate"
    ]
    resources = [
      "arn:aws:ec2:${var.region}:*:fleet/*",
      "arn:aws:ec2:${var.region}:*:instance/*",
      "arn:aws:ec2:${var.region}:*:volume/*",
      "arn:aws:ec2:${var.region}:*:network-interface/*",
      "arn:aws:ec2:${var.region}:*:launch-template/*",
      "arn:aws:ec2:${var.region}:*:spot-instances-request/*"
    ]
  }

  statement {
    sid    = "AllowScopedResourceCreationTagging"
    effect = "Allow"
    actions = [
      "ec2:CreateTags"
    ]
    resources = [
      "arn:aws:ec2:${var.region}:*:fleet/*",
      "arn:aws:ec2:${var.region}:*:instance/*",
      "arn:aws:ec2:${var.region}:*:volume/*",
      "arn:aws:ec2:${var.region}:*:network-interface/*",
      "arn:aws:ec2:${var.region}:*:launch-template/*",
      "arn:aws:ec2:${var.region}:*:spot-instances-request/*"
    ]
  }

  statement {
    sid    = "AllowScopedResourceTagging"
    effect = "Allow"
    actions = [
      "ec2:CreateTags"
    ]
    resources = [
      "arn:aws:ec2:${var.region}:*:instance/*"
    ]
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate"
    ]
    resources = [
      "arn:aws:ec2:${var.region}:*:instance/*",
      "arn:aws:ec2:${var.region}:*:launch-template/*"
    ]
  }

  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowSSMReadActions"
    effect = "Allow"
    actions = [
      "ssm:GetParameter"
    ]
    resources = [
      "arn:aws:ssm:${var.region}::parameter/aws/service/*"
    ]
  }

  statement {
    sid    = "AllowPricingReadActions"
    effect = "Allow"
    actions = [
      "pricing:GetProducts"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage"
    ]
    resources = ["arn:aws:sqs:${var.region}:*:${var.cluster_name}"]
  }

  statement {
    sid    = "AllowPassNodeIAMRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      module.eks.node_instance_role_arn
    ]
  }

  statement {
    sid    = "AllowScopedInstanceProfileCreationActions"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile"
    ]
    resources = [
      "arn:aws:iam::*:instance-profile/*"
    ]
  }

  statement {
    sid    = "AllowScopedInstanceProfileTagActions"
    effect = "Allow"
    actions = [
      "iam:TagInstanceProfile"
    ]
    resources = [
      "arn:aws:iam::*:instance-profile/*"
    ]
  }

  statement {
    sid    = "AllowScopedInstanceProfileActions"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile"
    ]
    resources = [
      "arn:aws:iam::*:instance-profile/*"
    ]
  }

  statement {
    sid    = "AllowInstanceProfileReadActions"
    effect = "Allow"
    actions = [
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfiles"
    ]
    resources = [
      "arn:aws:iam::*:instance-profile/*"
    ]
  }

  statement {
    sid    = "AllowAPIServerEndpointDiscovery"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster"
    ]
    resources = [
      "arn:aws:eks:${var.region}:*:cluster/${var.cluster_name}"
    ]
  }
}

resource "aws_iam_role_policy" "karpenter_controller_policy" {
  name   = "${var.cluster_name}-karpenter-controller-policy"
  role   = aws_iam_role.karpenter_controller_role.id
  policy = data.aws_iam_policy_document.karpenter_controller_policy.json
}
