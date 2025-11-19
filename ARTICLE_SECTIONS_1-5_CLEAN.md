# Sections 1-5 Clean Template

# Copy this content to replace lines 1-435 in eks-karpenter-article.md

# Navigating AWS EKS with Terraform: Configuring Karpenter for Just-in-Time Node Provisioning

_Author: Oluwafemi Lawal_

_Series: Navigating AWS EKS with Terraform_

In the [previous part of the series](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-implementing-cluster-auoscaler-in-your-eks-cluster-p54), we installed and configured the **Kubernetes Cluster Autoscaler (CA)** on an EKS cluster provisioned with Terraform. That article showed how to let Kubernetes resize **existing** node groups when Pods can't be scheduled.

In this article, we'll set up **Karpenter** — an open-source autoscaling solution from AWS that goes beyond resizing. Instead of only scaling node groups you've already created, **Karpenter talks directly to AWS and launches the _right_ EC2 instances on demand** to fit the Pods that are actually pending.

We will:

1. Reuse the EKS cluster and OIDC setup from earlier articles.
2. Create the Karpenter IAM role and policies with Terraform.
3. Install Karpenter into the cluster using Helm.
4. Create a Provisioner and AWSNodeTemplate that tells Karpenter what kinds of instances it's allowed to create.
5. Test that a pending Pod triggers Karpenter to create a new node.
6. Observe how Karpenter automatically removes nodes when they're no longer needed.

This keeps the same "Terraform-first" style you used for the Cluster Autoscaler article, so it fits seamlessly into your repo.

---

## 1. Why Karpenter When We Already Have Cluster Autoscaler?

Cluster Autoscaler works best when:

- You know your instance types ahead of time
- You manage node groups in Terraform
- You just want to scale those groups up and down

Karpenter is better when:

- Workloads are diverse (CPU, memory, availability zones)
- You want to use Spot instances easily
- You don't want to manage many node groups
- You want faster scale-out (seconds vs minutes)
- You need bin-packing optimization across different instance types

So think of this as the "modern autoscaling" counterpart to your CA article. Karpenter makes provisioning decisions based on the actual Pod requirements rather than scaling predefined node groups.

---

## 2. Prerequisites

You should already have:

- An **EKS cluster** (from your [previous Terraform articles](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-understanding-eks-cluster-configuration-2f6o))
- **OIDC** enabled on the cluster (we used this for IRSA before)
- `kubectl` and `helm` installed locally
- A place in your repo to drop new Terraform files (e.g. root of `demo-eks-cluster`)
- Terraform configured with your AWS credentials

If you're following along from the Cluster Autoscaler article, we'll be creating a new branch called `feature/karpenter` to implement these changes.

---

## 3. Prepare Your EKS Cluster

Before we dive into Karpenter-specific resources, we need to make a few modifications to our EKS cluster configuration to support Karpenter's discovery mechanism.

### Update EKS Module Tags

Karpenter uses tags to discover subnets and security groups. We need to update our `eks.tf` file to add the appropriate tags:

```hcl
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

  additional_launch_template_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
```

The key change here is replacing the Cluster Autoscaler specific tags with `karpenter.sh/discovery`. This tag allows Karpenter to discover which subnets and security groups it should use when provisioning nodes.

---

## 4. Terraform: IAM for Karpenter

Create a new file at the root of your repo called **`karpenter.tf`**. This file will contain all the IAM resources needed for Karpenter to function.

```hcl
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
```

The Karpenter controller policy is comprehensive and gives Karpenter the permissions it needs to:

- Launch and terminate EC2 instances
- Create and manage launch templates
- Describe EC2 resources (subnets, security groups, instance types, etc.)
- Manage instance profiles
- Tag resources appropriately

The full policy is quite extensive (covering EC2, IAM, SSM, and EKS actions), so I've included the complete version in the [repository](https://github.com/Femi-lawal/demo-eks-cluster/blob/feature/karpenter/karpenter.tf).

### Update IAM Role Mappings

We also need to update the `eks.tf` file to include the Karpenter role in the aws-auth ConfigMap:

```hcl
additional_role_mappings = [
  {
    rolearn  = aws_iam_role.karpenter_controller_role.arn
    username = "system:serviceaccount:karpenter:karpenter"
    groups   = ["system:masters"]
  }
]
```

### Update Terraform Outputs

Update your `ouput.tf` file to expose the necessary values for our deployment scripts:

```hcl
output "karpenter_controller_role_arn" {
  description = "The ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller_role.arn
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

### Apply Terraform Changes

Now apply these changes:

```bash
terraform init
terraform plan
terraform apply
```

You should see the new Karpenter IAM role and updated tags in your Terraform state.

---

## 5. Install Karpenter using Helm

Similar to the Cluster Autoscaler deployment, I've created a script to automate the Karpenter installation. Create a file called `scripts/deploy_karpenter.sh`:

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
export KARPENTER_VERSION="v0.37.0"

helm repo add karpenter https://charts.karpenter.sh/ || true
helm repo update

helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version ${KARPENTER_VERSION} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set settings.interruptionQueue=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait || true

# Wait for Karpenter to be ready
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n karpenter || true
```

This script does several things:

1. Retrieves necessary values from Terraform outputs (avoiding hardcoded values)
2. Updates your kubectl context to point to the EKS cluster
3. Creates the Karpenter namespace and service account with the IRSA annotation
4. Installs Karpenter via Helm with appropriate configuration
5. Waits for Karpenter to become available

Make the script executable and run it:

```bash
chmod +x scripts/deploy_karpenter.sh
./scripts/deploy_karpenter.sh
```

Verify Karpenter is running:

```bash
kubectl get pods -n karpenter
```

You should see the Karpenter controller pod in a Running state.

---
