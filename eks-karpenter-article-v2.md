# Navigating AWS EKS with Terraform: Configuring Karpenter for Just-in-Time Node Provisioning

In this article, we will integrate Karpenter, which will enable our cluster to provision nodes dynamically based on actual workload requirements. Unlike Cluster Autoscaler which scales existing node groups, Karpenter provisions exactly the right-sized nodes on demand. We will need to make some adjustments to our EKS module.

## Prerequisites

Ensure you have:

- An active AWS account
- Terraform installed and configured
- Helm installed
- kubectl

## Setup Overview

In the [previous part of the series](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-implementing-cluster-auoscaler-in-your-eks-cluster-p54), we installed and configured the **Kubernetes Cluster Autoscaler (CA)** on an EKS cluster provisioned with Terraform. That article showed how to let Kubernetes resize **existing** node groups when Pods can't be scheduled.

Karpenter takes a different approach — an open-source autoscaling solution from AWS that goes beyond resizing existing node groups. Instead, **Karpenter talks directly to AWS and launches the _right_ EC2 instances on demand** to fit the Pods that are actually pending.

## Prepare Your EKS Cluster

Ensure your EKS cluster is ready. If needed, [refer back to our guide on setting up an EKS cluster using Terraform](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-understanding-eks-cluster-configuration-2f6o)

## Modifications

To support Karpenter's auto-discovery feature, we need to update the tags on our EKS resources. Unlike Cluster Autoscaler which used `k8s.io/cluster-autoscaler/*` tags, Karpenter uses `karpenter.sh/discovery` tags to identify the subnets and security groups it can use when provisioning nodes.

### Update EKS Module to Support New Parameters

First, we need to extend our EKS module to support the parameters required for Karpenter. Add these variables to `modules/aws/eks/v1/variables.tf`:

```terraform
variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = null
}

variable "additional_role_mappings" {
  description = "Additional IAM role mappings for aws-auth ConfigMap"
  type = list(object({
    rolearn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "additional_launch_template_tags" {
  description = "Additional tags to add to the launch template"
  type        = map(string)
  default     = {}
}
```

Update `modules/aws/eks/v1/main.tf` to use these variables:

1. Add version to the EKS cluster:

```terraform
resource "aws_eks_cluster" "main" {
  name                      = var.cluster_name
  role_arn                  = aws_iam_role.eks_cluster_role.arn
  enabled_cluster_log_types = var.enabled_cluster_log_types
  version                   = var.eks_cluster_version  # Add this line
  # ... rest of configuration
}
```

2. Update the launch template tags to merge additional tags:

```terraform
resource "aws_launch_template" "eks_node_group" {
  # ... existing configuration ...

  tags = merge(
    {
      "Name"                                      = "${var.cluster_name}-eks-node-group"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    },
    var.additional_launch_template_tags
  )
}
```

3. Update the aws-auth ConfigMap to include additional role mappings:

```terraform
resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode(concat(
      [
        {
          rolearn  = aws_iam_role.eks_admins_role.arn
          username = aws_iam_role.eks_admins_role.name
          groups   = ["system:masters"]
        },
        {
          rolearn  = aws_iam_role.node_role.arn
          username = "system:node:{{EC2PrivateDNSName}}"
          groups   = ["system:bootstrappers", "system:nodes"]
        }
      ],
      var.additional_role_mappings
    ))
    # ... rest of configuration
  }
}
```

4. Update the nodes security group to include additional tags:

```terraform
resource "aws_security_group" "eks_nodes_sg" {
  name        = "${var.cluster_name}-eks-nodes-sg"
  description = "Security group for all nodes in the cluster"
  vpc_id      = var.vpc_id

  tags = merge(
    {
      Name                                        = "${var.cluster_name}-eks-nodes-sg"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    },
    var.additional_launch_template_tags
  )
}
```

5. Add new outputs to `modules/aws/eks/v1/outputs.tf`:

```terraform
output "oidc_provider_url" {
  description = "The OIDC URL of the Cluster"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "node_instance_role_arn" {
  description = "The ARN of the node instance role"
  value       = aws_iam_role.node_role.arn
}
```

### Update VPC and EKS Configuration

**Critical:** Karpenter needs to discover subnets and security groups using tags. **Only private subnets should be tagged** - if public subnets are tagged, Karpenter may provision nodes without public IPs that cannot reach the cluster.

Update `vpc.tf` to add Karpenter discovery tags to **private subnets only**:

```terraform
module "vpc" {
  source = "./modules/aws/vpc/v1"

  vpc_name             = "${var.cluster_name}-vpc"
  cidr_block           = "10.0.0.0/16"
  nat_gateway          = true
  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_count  = 3
  private_subnet_count = 3
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
    # DO NOT add karpenter.sh/discovery tag to public subnets
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "karpenter.sh/discovery"                    = var.cluster_name  # Add this tag to private subnets only
  }
}
```

Now update `eks.tf` to configure the EKS cluster with Karpenter support:

```terraform
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
```

> **📸 Screenshot Placeholder 1: EKS Cluster Configuration**
>
> Show the `eks.tf` file in VS Code or your editor with the highlighted sections:
>
> - The `eks_cluster_version = "1.31"` line
> - The `additional_role_mappings` block for Karpenter
> - The `additional_launch_template_tags` block with the karpenter.sh/discovery tag
>
> This helps readers see the exact configuration in context.

## Create IAM Role for Karpenter

The Karpenter controller needs specific permissions to interact with EC2 instances and AWS services. We'll create an IAM role that uses IRSA (IAM Roles for Service Accounts) to allow the Karpenter pods to assume this role securely.

Create a new file called `karpenter.tf` at the root of your repository:

```terraform
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
      "iam:GetInstanceProfile"
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
```

The Karpenter controller policy gives Karpenter the permissions it needs to:

- Launch and terminate EC2 instances
- Create and manage launch templates
- Describe EC2 resources (subnets, security groups, instance types, etc.)
- Manage instance profiles
- Tag resources appropriately

We also pass the role mapping to the config map in the EKS module (shown in the `eks.tf` above), which allows the Karpenter service account to assume this IAM role.

We also need to update our Terraform outputs in `ouput.tf` to expose values needed by our deployment scripts:

```terraform
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
```

We can then apply our changes with terraform:

```bash
terraform apply
```

> **📸 Screenshot Placeholder 2: Terraform Apply Output**
>
> Capture the terminal output showing:
>
> - `terraform apply` command execution
> - Resources being created (aws_iam_role.karpenter_controller_role, aws_iam_role_policy.karpenter_controller_policy)
> - Green "Apply complete!" message with resource count
> - Output values showing karpenter_controller_role_arn
>
> This validates that the Terraform configuration was applied successfully.

We can confirm our cluster is up and running in the AWS console.

> **📸 Screenshot Placeholder 3: Cluster in AWS Console**
>
> Show the AWS EKS console displaying:
>
> - Your EKS cluster in "Active" status
> - Cluster version (1.31)
> - Node group showing 2 nodes
>
> Similar to the Cluster Autoscaler article screenshot showing cluster state.

## Install Karpenter using Helm

We have created the role mapping that the karpenter service account will use, but we still need to create the actual service account. The manifest to create that will look like this:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: karpenter
  namespace: karpenter
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::<ACCOUNT_ID>:role/<IAM_ROLE_NAME>"
```

For simplicity (or just because I'm lazy), I have created scripts to help with the rest of the article. They make use of terraform outputs to avoid having to put placeholders or keep track of which command to run first.

The script `scripts/deploy_karpenter.sh` updates our kubectl context to that of the cluster, creates the service account for Karpenter with the IRSA annotation, and deploys Karpenter using helm:

```bash
#!/bin/bash
set -euxo pipefail

# Retrieve Terraform outputs
REGION=$(terraform output -raw aws_region)
CLUSTER_NAME=$(terraform output -raw cluster_name)
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
NODE_INSTANCE_ROLE_ARN=$(terraform output -raw node_instance_role_arn)

# Extract the role name from the ARN
NODE_INSTANCE_ROLE_NAME=$(echo $NODE_INSTANCE_ROLE_ARN | awk -F'/' '{print $NF}')

# Update kubeconfig
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Create the karpenter namespace
kubectl create namespace karpenter || true

# Create the service account for Karpenter
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: karpenter
  namespace: karpenter
  annotations:
    eks.amazonaws.com/role-arn: $KARPENTER_ROLE_ARN
EOF

# Install Karpenter using Helm
export KARPENTER_VERSION="0.16.3"

helm repo add karpenter https://charts.karpenter.sh/ || true
helm repo update

helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version ${KARPENTER_VERSION} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set clusterName=${CLUSTER_NAME} \
  --set clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set aws.defaultInstanceProfile=${NODE_INSTANCE_ROLE_NAME} \
  --set controller.resources.requests.cpu=500m \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set replicas=1 \
  --wait || true

# Wait for Karpenter to be ready
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n karpenter || true

# Wait additional time for webhook endpoints to be fully ready
echo "Waiting 30 seconds for Karpenter webhook endpoints to be ready..."
sleep 30

# Create EC2NodeClass
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  amiFamily: AL2
  instanceProfile: ${NODE_INSTANCE_ROLE_NAME}
  subnetSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
EOF

# Create NodePool
kubectl apply -f kubernetes/karpenter/nodepool.yaml

# Deploy test deployment (starts at 0 replicas)
kubectl apply -f kubernetes/karpenter/test-deployment.yaml

echo "Karpenter installation completed successfully!"
echo ""
echo "To verify Karpenter is running:"
echo "kubectl get pods -n karpenter"
echo ""
echo "To view Karpenter logs:"
echo "kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter"
echo ""
echo "To test autoscaling, run:"
echo "./scripts/test_karpenter.sh"
```

The script also creates the Karpenter `AWSNodeTemplate` (which tells Karpenter how to configure EC2 instances) and applies the `Provisioner` configuration from `kubernetes/karpenter/nodepool.yaml`:

```yaml
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
    - key: kubernetes.io/os
      operator: In
      values: ["linux"]
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["on-demand"]
    - key: karpenter.k8s.aws/instance-category
      operator: In
      values: ["t"]
    - key: karpenter.k8s.aws/instance-generation
      operator: Gt
      values: ["2"]
  providerRef:
    name: default
  limits:
    resources:
      cpu: 10
  ttlSecondsAfterEmpty: 30
  ttlSecondsUntilExpired: 2592000 # 30 days
```

This Provisioner configuration:

- Only provisions **amd64 Linux** nodes
- Uses **on-demand** instances (you can add "spot" for cost savings)
- Restricts to **t-family** instances (t3, t3a, etc.) **generation 3 or higher**
- Sets a CPU limit of **10 vCPUs** total across all Karpenter-provisioned nodes
- Automatically deprovisions nodes **30 seconds** after they become empty
- Expires nodes after **30 days** for security patching

Run the deployment script:

```bash
chmod +x scripts/deploy_karpenter.sh
./scripts/deploy_karpenter.sh
```

> **📸 Screenshot Placeholder 4: Karpenter Deployment Script Output**
>
> Show terminal output from running `deploy_karpenter.sh` displaying:
>
> - Helm repo updates
> - Karpenter installation progress
> - "Karpenter installation completed successfully!" message
> - Instructions for verifying Karpenter
>
> Similar style to the Cluster Autoscaler deployment screenshot.

Verify Karpenter is running:

```bash
kubectl get pods -n karpenter
```

> **📸 Screenshot Placeholder 5: Karpenter Pod Running**
>
> Show the output of `kubectl get pods -n karpenter` displaying:
>
> - Pod name (e.g., karpenter-xxxxxxxxxx-xxxxx)
> - STATUS: Running
> - READY: 1/1
> - AGE: showing pod has been running

You will notice that we only have two nodes at the moment.

> **📸 Screenshot Placeholder 6: Initial Node Count**
>
> Show `kubectl get nodes` output with only 2 nodes (the original managed node group).
> This establishes the baseline before Karpenter provisions additional nodes.

## Deploy Applications To Trigger Scale Up Operation

Next, we will deploy a test workload to the cluster. The test deployment requests resources that our two small EC2 instances cannot fully accommodate. Karpenter will come to the rescue and provision an additional node to make our cluster healthy again.

The test deployment `kubernetes/karpenter/test-deployment.yaml` looks like this:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
  namespace: default
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "1"
              memory: "1.5Gi"
```

The script `scripts/test_karpenter.sh` scales this deployment from 0 to 5 replicas:

```bash
#!/bin/bash
set -euxo pipefail

echo "Scaling up the inflate deployment to trigger Karpenter provisioning..."

# Scale up the deployment to trigger node provisioning
kubectl scale deployment inflate --replicas=5 -n default

echo ""
echo "Deployment scaled to 5 replicas. Monitoring cluster events..."
```

Run the test script:

```bash
chmod +x scripts/test_karpenter.sh
./scripts/test_karpenter.sh
```

Watch Karpenter logs to see it making provisioning decisions:

```bash
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter -c controller
```

You'll see logs like:

```
INFO    controller.provisioner  found provisionable pod(s)
INFO    controller.provisioner  computed new node(s) to fit pod(s)
INFO    controller.provisioner  created node with 1 pods requesting cpu=1000m, memory=1536Mi
```

> **📸 Screenshot Placeholder 7: Karpenter Provisioning in Action**
>
> A multi-panel screenshot showing:
>
> **Panel 1 - Karpenter Logs:** > `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter` showing:
>
> - "found provisionable pod(s)"
> - "computed new node(s) to fit pod(s)"
> - "launching node"
>
> **Panel 2 - Nodes After Provisioning:** > `kubectl get nodes` now showing 3 nodes (2 original + 1 new Karpenter node)
>
> **Panel 3 - Pods Running:** > `kubectl get pods -n default -l app=inflate` showing all 5 inflate pods in Running state
>
> This is the key demonstration of Karpenter's automatic node provisioning capability, similar to the Cluster Autoscaler article's scale-up screenshot.

You will notice that Karpenter did its job and added an extra node to our cluster. The deployments were able to succeed.

> **📸 Screenshot Placeholder 8: AWS Console View After Scale-Up**
>
> Show the AWS EKS console or EC2 console displaying:
>
> - 3 total EC2 instances (2 from managed node group + 1 from Karpenter)
> - The Karpenter-provisioned instance tagged with `karpenter.sh/discovery`
>
> Similar to the Cluster Autoscaler article showing the scale-up in AWS console.

If you check the events of your cluster, you will be able to find the scale up events.

> **📸 Screenshot Placeholder 9: Scale Up Events**
>
> Show Kubernetes events or Karpenter logs showing:
>
> - Node provisioning events
> - Pod scheduling events
> - Timestamps showing rapid provisioning (30-60 seconds)
>
> Similar to the Cluster Autoscaler scale-up event screenshot.

## Scale Down Operation

Now we will scale down the test deployment and watch to see if Karpenter automatically removes the node.

The cleanup script `scripts/cleanup_karpenter_test.sh` scales the deployment back to 0:

```bash
#!/bin/bash
set -euxo pipefail

echo "Scaling down the inflate deployment..."

# Scale down the deployment
kubectl scale deployment inflate --replicas=0 -n default

echo ""
echo "Deployment scaled to 0 replicas."
echo "Watch nodes with: kubectl get nodes -w"
echo "Karpenter should remove the empty node in about 30 seconds (ttlSecondsAfterEmpty)"
```

Run the cleanup script:

```bash
chmod +x scripts/cleanup_karpenter_test.sh
./scripts/cleanup_karpenter_test.sh
```

Monitor the nodes:

```bash
kubectl get nodes -w
```

After about 30 seconds (the `ttlSecondsAfterEmpty` setting in our Provisioner), Karpenter will:

1. Cordon the empty node
2. Drain any remaining system pods
3. Terminate the EC2 instance

You'll see this in the Karpenter logs:

```
INFO    controller.deprovisioning   deprovisioning via emptiness delete
INFO    controller.deprovisioning   cordoned node
INFO    controller.deprovisioning   deleted node
```

> **📸 Screenshot Placeholder 10: Karpenter Deprovisioning**
>
> A time-series screenshot showing:
>
> **T+0s - After scaling to 0:** > `kubectl get nodes` showing 3 nodes total
>
> **T+30s - Karpenter deprovisioning:**
> Karpenter logs showing:
>
> - "deprovisioning via emptiness delete"
> - "cordoned node"
> - "deleted node"
>
> **T+60s - Node removed:** > `kubectl get nodes` showing back to 2 nodes
>
> This demonstrates Karpenter's fast scale-down capability (30-60 seconds vs Cluster Autoscaler's 10+ minutes).

Karpenter scales down the cluster back to two nodes much faster than Cluster Autoscaler (30-60 seconds vs 10+ minutes).

> **📸 Screenshot Placeholder 11: AWS Console After Scale-Down**
>
> Show the AWS EKS console displaying:
>
> - Back to 2 nodes (only managed node group nodes)
> - Karpenter-provisioned instance has been terminated
>
> Similar to the Cluster Autoscaler article's final screenshot showing cluster scaled down.

## Understanding Karpenter's Advantages

Through this exercise, you've seen several advantages of Karpenter over Cluster Autoscaler:

### Faster Provisioning

Karpenter provisions nodes in **30-60 seconds** because it launches instances directly rather than scaling Auto Scaling Groups.

### No Pre-defined Node Groups

You don't need to define multiple node groups for different instance types. Karpenter chooses the best fit automatically based on pending pod requirements.

### Better Bin Packing

Karpenter looks at all pending pods together and provisions nodes that maximize utilization.

### Faster Scale Down

Karpenter can deprovision nodes in **30-60 seconds** vs 10+ minutes for Cluster Autoscaler.

### Consolidation

Karpenter actively consolidates nodes to reduce costs, even moving pods to smaller instances when possible.

### Spot Instance Support

Adding spot instances is as simple as adding `"spot"` to the `karpenter.sh/capacity-type` values in your Provisioner.

## Comparison: Cluster Autoscaler vs Karpenter

| Feature                | Cluster Autoscaler | Karpenter      |
| ---------------------- | ------------------ | -------------- |
| **Provisioning Time**  | 2-5 minutes        | 30-60 seconds  |
| **Node Groups**        | Required           | Not required   |
| **Instance Selection** | Predefined         | Dynamic        |
| **Scale Down Time**    | 10+ minutes        | 30-60 seconds  |
| **Spot Support**       | Via ASG            | Native, simple |
| **Bin Packing**        | Limited            | Advanced       |
| **Consolidation**      | No                 | Yes            |
| **Configuration**      | Via ASG tags       | Via CRDs       |

The complete code used in this article can be found on [this branch of the repository](https://github.com/Femi-lawal/demo-eks-cluster/tree/feature/karpenter)

## Troubleshooting

### Webhook Endpoint Not Ready

If you encounter an error like:

```
Error from server (InternalError): error when creating "STDIN": Internal error occurred: failed calling webhook "defaulting.webhook.provisioners.karpenter.sh": failed to call webhook: Post "https://karpenter.karpenter.svc:443/?timeout=10s": no endpoints available for service "karpenter"
```

This occurs when Karpenter's webhook service isn't fully ready yet. The deployment script now includes a 30-second wait after the deployment becomes available to ensure the webhook endpoints are ready.

### Karpenter Can't Find Subnets

If Karpenter logs show errors like:

```
no subnets matched selector map[karpenter.sh/discovery:demo-cluster]
```

Ensure you've added the `karpenter.sh/discovery` tags to:
1. Your VPC **private subnets only** (not public subnets)
2. Your EKS cluster security group

The tags must be on the actual AWS resources, not just the launch template.

### Nodes Stuck in NotReady State

If Karpenter provisions nodes that never become Ready (kubelet never starts):

1. **Check subnet type**: Nodes must be in **private subnets** with NAT gateway access. If nodes are provisioned in public subnets without public IPs, they cannot reach the EKS API server.
2. **Verify tags**: Only tag private subnets with `karpenter.sh/discovery`. If public subnets are tagged, Karpenter may use them.
3. **Check security groups**: Ensure the node security group allows communication with the EKS control plane.

Solution: Remove `karpenter.sh/discovery` tag from public subnets and delete/recreate stuck nodes.

### Terraform Version Issues

If you encounter version constraint errors, ensure you're using Terraform >= 1.5.1. Update your `versions.tf`:

```terraform
terraform {
  required_version = ">= 1.5.1"
  # ...
}
```

## Conclusion

Your EKS cluster now has a functioning Karpenter setup that is adept at provisioning node resources in response to workload changes. Karpenter provides faster scaling, smarter instance selection, and better cost optimization compared to traditional Cluster Autoscaler.

Don't forget to clean up any resources you are not using, it can get quite expensive.

To clean up Karpenter resources:

```bash
chmod +x scripts/delete_all.sh
./scripts/delete_all.sh
```

If you want to destroy all infrastructure:

```bash
terraform destroy
```

**Important:** Karpenter-provisioned nodes should be cleaned up automatically when you delete the Provisioner, but you may want to verify in the AWS console that no orphaned instances remain.

For more advanced configurations and best practices, refer to:

- [Karpenter Documentation](https://karpenter.sh/)
- [AWS EKS Best Practices Guide - Karpenter](https://aws.github.io/aws-eks-best-practices/karpenter/)
