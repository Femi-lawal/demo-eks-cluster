## Introduction

Want to serve machine learning models on Kubernetes without the complexity of managing infrastructure manually? This tutorial shows you how to deploy ML models on Amazon EKS using KServe, with all infrastructure managed as code using Terraform.

**What makes this approach different?** Everything is automated and reproducible. No manual clicking through AWS console, no copy-pasting credentials into YAML files. Just clean, version-controlled infrastructure code.

### Who Is This For?

This article is for you if:

- You have (or want) an EKS cluster and want to add ML model serving capabilities
- You prefer Infrastructure as Code over manual configuration
- You want to understand how AWS IAM, Kubernetes, and S3 work together securely
- You're building a machine learning platform and need a solid foundation

### What You'll Build

By the end of this tutorial, you'll have:

- ✅ A reusable Terraform module for KServe IAM permissions
- ✅ ML models served from your EKS cluster
- ✅ Secure S3 access without hardcoding credentials
- ✅ Automated deployment and testing scripts
- ✅ A production-ready foundation for ML model serving

### Prerequisites

**Infrastructure you need:**

- An existing EKS cluster with OIDC enabled ([Part 1 of this series](https://github.com/Femi-lawal/demo-eks-cluster))
- 3 worker nodes (t3a.small or larger)
- Amazon Linux 2023 AMI (required for Kubernetes 1.33+)

**Tools you need installed:**

- `kubectl` - Kubernetes CLI
- `terraform` >= 1.5.0 - Infrastructure as Code tool
- `aws` CLI - Configured with appropriate credentials
- `curl` - For testing endpoints
- `python3` (optional) - For the testing script

**Skills helpful but not required:**

- Basic Kubernetes concepts (pods, deployments, services)
- Basic Terraform syntax (we'll walk through everything)
- Understanding of IAM roles (we'll explain as we go)

> **New to this series?** This article builds on an existing EKS cluster setup. You can still follow along if you have any EKS cluster with OIDC enabled, but you'll need to adapt the Terraform module paths to your structure.

---

## What We're Building Today

This article shows you how to add ML model serving to an existing EKS cluster. Here's what we'll create:

1. **A new Terraform module** at `modules/aws/kserve-irsa/v1/`

   - IAM policy for reading models from S3
   - IAM role that Kubernetes pods can assume securely
   - All following best practices for modular Terraform code

2. **A root-level Terraform file** `kserve-irsa.tf`

   - Invokes the module with your cluster information
   - Keeps your root configuration clean and maintainable

3. **Automation scripts** in `scripts/` directory
4. **Automation scripts** in `scripts/` directory

   - `setup-kserve-complete.sh` – One command to deploy everything
   - `test-kserve-updated.sh` – Automated testing with a sample sklearn model
   - `teardown-kserve.sh` – Clean removal when you're done

5. **Kubernetes resources** that get deployed
   - Namespace for KServe workloads
   - Service account with AWS IAM permissions
   - Deployment running the KServe model server
   - Service for accessing predictions

### The Big Picture

Here's how everything fits together:

```
┌─────────────────────────────────────────────────────────┐
│  Your Laptop                                            │
│  ├── terraform apply    → Creates IAM role + S3 bucket │
│  └── ./scripts/setup... → Deploys to Kubernetes        │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│  AWS                                                     │
│  ├── IAM Role (created by Terraform)                   │
│  │   └── Can read from S3 bucket                       │
│  ├── S3 Bucket (ml-model-artifacts-*)                  │
│  │   └── Contains your trained ML models               │
│  └── EKS Cluster                                        │
│      └── Pod (running KServe)                          │
│          ├── Uses IAM role via IRSA (no keys!)         │
│          ├── Downloads model from S3                   │
│          └── Serves predictions via HTTP API           │
└─────────────────────────────────────────────────────────┘
```

**Key Concept - IRSA (IAM Roles for Service Accounts):**  
Instead of hardcoding AWS access keys in your pod, IRSA lets Kubernetes pods securely assume AWS IAM roles. This is the AWS-recommended best practice for giving pods AWS permissions.

---

## 1. Understanding the Architecture

Before we dive into code, let's understand what makes this approach work and why we're doing it this way.

### Why Direct Deployments Instead of InferenceService CRDs?

KServe traditionally uses Kubernetes Custom Resource Definitions (CRDs) called `InferenceService`. However, in standard EKS networking configurations, there can be connectivity issues between the EKS API server (in AWS-managed VPC) and pod-based webhooks (in your VPC).

**Our solution:** Use standard Kubernetes Deployments with KServe container images. This gives you:

- ✅ All the benefits of KServe's model servers
- ✅ No webhook dependency
- ✅ Simpler architecture
- ✅ More transparent configuration
- ✅ Easier troubleshooting

### How Models Get Loaded

1. **You upload** a trained model to S3 (our script does this for you)
2. **Init container** downloads the model when pod starts
3. **Main container** (KServe server) loads model from local disk and serves predictions
4. **You send** HTTP requests to get predictions

This "storage initializer pattern" is standard in ML serving systems.

---

## 2. The KServe IRSA Terraform Module

Let's build the foundation: a Terraform module that creates the IAM permissions KServe needs to access S3.

### Why Use a Module?

Instead of putting all IAM resources directly in your root Terraform code, we create a reusable module. Benefits:

1. **Reusability** – Use it across multiple clusters or projects
2. **Testability** – Test the module independently
3. **Maintainability** – Changes are isolated
4. **Consistency** – Follows the same pattern as your EKS and VPC modules
5. **Best Practice** – This is how production Terraform code is organized

   - `setup-kserve-complete.sh` – Complete automated installation using direct Kubernetes deployments
   - `test-kserve-updated.sh` – Automated testing with a sample sklearn model
   - `teardown-kserve.sh` – Clean resource removal
   - All scripts read from Terraform outputs automatically

6. **Kubernetes manifests** under `k8s/kserve/` directory
   - Namespace and service account (with IRSA annotation)
   - Direct Kubernetes Deployment with KServe containers
   - Generated dynamically by the setup script

**Important Architecture Note**: This implementation uses **direct Kubernetes Deployments** with KServe container images rather than the typical InferenceService custom resources. This approach works reliably on EKS by avoiding webhook connectivity issues that can occur in standard EKS networking configurations.

### What You'll Need

Before starting, make sure you have:

- ✅ An existing EKS cluster (from [earlier in this series](https://github.com/Femi-lawal/demo-eks-cluster))
- ✅ `kubectl` installed and configured
- ✅ `terraform` installed (version >= 1.5.0)
- ✅ `aws` CLI configured with appropriate credentials
- ✅ Basic understanding of Kubernetes concepts (pods, deployments, services)
- ✅ Familiarity with Terraform (or willingness to learn as you go!)

**Glossary of Terms:**

- **IRSA** (IAM Roles for Service Accounts): Allows Kubernetes pods to assume AWS IAM roles securely
- **OIDC** (OpenID Connect): Authentication protocol used by EKS for IRSA
- **CRD** (Custom Resource Definition): Extends Kubernetes API with custom resource types
- **Webhook**: HTTP callback used by Kubernetes to validate/mutate resources during creation

This keeps everything organized: Terraform makes AWS objects using modules, scripts automate deployment, and YAML defines Kubernetes objects.

---

## 2. The KServe IRSA Module (Terraform Best Practice)

Instead of putting all the IAM resources directly in the root, we follow the existing pattern and create a **reusable module**.

### Module Structure

```
modules/aws/kserve-irsa/v1/
├── main.tf           # IAM resources and policies
├── variables.tf      # Input parameters
├── outputs.tf        # Values to expose
├── versions.tf       # Provider requirements
└── README.md         # Module documentation
```

This matches the pattern you already have for `eks/v1` and `vpc/v1`.

### Module: `modules/aws/kserve-irsa/v1/main.tf`

```hcl
#############################################
# KServe IRSA Module
# Creates IAM role and policy for KServe to access S3 using IRSA
#############################################

data "aws_caller_identity" "current" {}

############################################################
# IAM policy: allow reading models from S3 bucket
############################################################
data "aws_iam_policy_document" "kserve_s3_read" {
  statement {
    sid = "AllowModelDownload"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.model_bucket_name}",
      "arn:aws:s3:::${var.model_bucket_name}/*"
    ]
  }
}

resource "aws_iam_policy" "kserve_s3_read" {
  name        = "${var.cluster_name}-kserve-s3-read"
  description = "Allow KServe to download models from S3"
  policy      = data.aws_iam_policy_document.kserve_s3_read.json
}

############################################################
# IAM role for service account (IRSA)
############################################################

data "aws_iam_policy_document" "kserve_irsa_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.kserve_namespace}:${var.kserve_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kserve_irsa" {
  name               = "${var.cluster_name}-kserve-irsa"
  assume_role_policy = data.aws_iam_policy_document.kserve_irsa_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "kserve_s3_read_attach" {
  role       = aws_iam_role.kserve_irsa.name
  policy_arn = aws_iam_policy.kserve_s3_read.arn
}
```

### Module: `modules/aws/kserve-irsa/v1/variables.tf`

```hcl
variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the OIDC provider for the EKS cluster"
}

variable "oidc_issuer_url" {
  type        = string
  description = "OIDC issuer URL for the EKS cluster"
}

variable "model_bucket_name" {
  type        = string
  description = "Name of the S3 bucket containing ML models"
}

variable "kserve_namespace" {
  type        = string
  description = "Kubernetes namespace for KServe"
  default     = "kserve"
}

variable "kserve_service_account" {
  type        = string
  description = "Kubernetes service account name for KServe"
  default     = "kserve-sa"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to IAM resources"
  default     = {}
}
```

### Module: `modules/aws/kserve-irsa/v1/outputs.tf`

```hcl
output "iam_role_arn" {
  description = "ARN of the IAM role for KServe IRSA"
  value       = aws_iam_role.kserve_irsa.arn
}

output "iam_role_name" {
  description = "Name of the IAM role for KServe IRSA"
  value       = aws_iam_role.kserve_irsa.name
}

output "iam_policy_arn" {
  description = "ARN of the IAM policy for S3 read access"
  value       = aws_iam_policy.kserve_s3_read.arn
}

output "kserve_namespace" {
  description = "Kubernetes namespace for KServe"
  value       = var.kserve_namespace
}

output "kserve_service_account" {
  description = "Kubernetes service account name for KServe"
  value       = var.kserve_service_account
}

output "model_bucket_name" {
  description = "S3 bucket name for KServe models"
  value       = var.model_bucket_name
}
```

### Module: `modules/aws/kserve-irsa/v1/versions.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
  }
}
```

### Why a Module?

This follows Terraform best practices and matches your existing repo structure:

1. **Reusability** – Can be used across multiple clusters or projects
2. **Versioning** – The `/v1` suffix allows for future version management
3. **Testability** – Module can be tested independently
4. **Consistency** – Matches your `eks/v1` and `vpc/v1` pattern
5. **Documentation** – Each module is self-documented
6. **Maintainability** – Changes are isolated within the module

---

## 3. Root-Level Terraform Configuration

Create a new file in the **root** of your `demo-eks-cluster` repo named **`kserve-irsa.tf`**:

```hcl
#############################################
# kserve-irsa.tf
# KServe IRSA setup using modular design
# Creates IAM role and policy for KServe to access S3 using IRSA
#############################################

# Get current AWS account information
data "aws_caller_identity" "current" {}

# Reference the existing EKS cluster
data "aws_eks_cluster" "this" {
  name       = var.cluster_name
  depends_on = [module.eks]
}

# Define S3 bucket name for ML models
locals {
  kserve_model_bucket = "ml-model-artifacts-${data.aws_caller_identity.current.account_id}"
}

############################################################
# KServe IRSA Module
############################################################
module "kserve_irsa" {
  source = "./modules/aws/kserve-irsa/v1"

  cluster_name      = var.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  model_bucket_name = local.kserve_model_bucket

  # Optional: customize these if needed
  kserve_namespace       = "kserve"
  kserve_service_account = "kserve-sa"

  tags = var.global_tags
}

############################################################
# Outputs
############################################################

output "kserve_irsa_role_arn" {
  description = "ARN of the IAM role for KServe IRSA"
  value       = module.kserve_irsa.iam_role_arn
}

output "kserve_model_bucket" {
  description = "S3 bucket name for KServe models"
  value       = module.kserve_irsa.model_bucket_name
}

output "kserve_namespace" {
  description = "Kubernetes namespace for KServe"
  value       = module.kserve_irsa.kserve_namespace
}

output "kserve_service_account" {
  description = "Kubernetes service account name for KServe"
  value       = module.kserve_irsa.kserve_service_account
}
```

### Notes on This Approach

- **Clean root config** – Only ~60 lines that invoke the module
- **Reuses existing resources** – Gets OIDC provider ARN from the `eks` module output
- **Dynamic bucket naming** – Uses AWS account ID to ensure uniqueness
- **Exposes outputs** – These are used by the automation scripts
- **Follows the pattern** – Same style as how you invoke `module.eks` and `module.vpc`

### Important: EKS Module Update for Kubernetes 1.33+

If you're running Kubernetes 1.33 or later, you need to update the default AMI type in your EKS module.

Edit `modules/aws/eks/v1/variables.tf`:

```hcl
variable "default_ami_type" {
  description = "The type of AMI to use for the node group. Valid values: AL2023_x86_64_STANDARD, AL2_x86_64, AL2_x86_64_GPU"
  type        = string
  default     = "AL2023_x86_64_STANDARD"  # Changed from AL2_x86_64
}
```

**Why?** Amazon Linux 2 (`AL2_x86_64`) only supports Kubernetes versions up to 1.32. Kubernetes 1.33+ requires Amazon Linux 2023 (`AL2023_x86_64_STANDARD`).

### Also: Remove Redundant OIDC Identity Provider Config

The EKS module had a redundant `aws_eks_identity_provider_config` resource that conflicts with the built-in OIDC provider. This has been removed from `modules/aws/eks/v1/main.tf`:

```hcl
# REMOVED - This was redundant
# resource "aws_eks_identity_provider_config" "eks" {
#   cluster_name = aws_eks_cluster.main.name
#   oidc {
#     identity_provider_config_name = "oidc"
#     client_id                     = aws_iam_openid_connect_provider.eks.id
#     issuer_url                    = aws_eks_cluster.main.identity[0].oidc[0].issuer
#   }
# }
```

EKS automatically creates the OIDC issuer; we only need the `aws_iam_openid_connect_provider` resource.

---

## 4. Automation Scripts (The Easy Way)

The **recommended way** to set up KServe is using the automation scripts. They handle everything automatically by reading from Terraform outputs.

### Script 1: `scripts/setup-kserve-complete.sh`

This script automates the entire setup process using a **direct Kubernetes Deployment** approach:

**What it does:**

- ✅ Checks prerequisites (kubectl, terraform, aws)
- ✅ Retrieves configuration from Terraform outputs automatically
- ✅ Configures kubectl for your EKS cluster
- ✅ Creates Kubernetes namespace and ServiceAccount with IRSA
- ✅ Generates deployment manifest with storage-initializer init container
- ✅ Deploys KServe sklearn server using standard Kubernetes Deployment
- ✅ Configures proper IRSA environment variables for S3 access
- ✅ Creates S3 bucket if it doesn't exist
- ✅ Waits for deployment to be ready

**Usage:**

```bash
bash scripts/setup-kserve-complete.sh
```

**Why Direct Deployments?** Standard EKS networking has challenges with admission webhooks (used by InferenceService CRDs). The direct deployment approach uses explicit init container configuration for the storage-initializer, bypassing webhook dependencies while maintaining full KServe functionality.

The script is **fully automated** – it reads `cluster_name`, `region`, `kserve_irsa_role_arn`, and `kserve_model_bucket` directly from `terraform output`. No manual configuration needed!

### Script 2: `scripts/test-kserve-updated.sh`

This script tests your KServe deployment:

**What it does:**

- ✅ Creates a sample sklearn iris model
- ✅ Uploads the model to S3
- ✅ Verifies the deployment is running
- ✅ Checks storage-initializer downloaded the model
- ✅ Tests the endpoint with a prediction request via port-forward
- ✅ Validates the response

**Usage:**

```bash
bash scripts/test-kserve-updated.sh
```

### Script 3: `scripts/teardown-kserve.sh`

Clean removal of all KServe resources:

```bash
bash scripts/teardown-kserve.sh
```

### Complete Setup (Two Commands)

```bash
# 1. Apply Terraform to create infrastructure
terraform apply

# 2. Run the setup script (~1 minute)
bash scripts/setup-kserve-complete.sh

# 3. Test that it works
bash scripts/test-kserve-updated.sh
```

That's it! The scripts handle everything else.

### What Gets Created

**Kubernetes Resources:**

- Namespace: `kserve`
- ServiceAccount: `kserve-sa` with IRSA annotation
- Deployment: `sklearn-iris` with storage-initializer init container
- Service: `sklearn-iris` (ClusterIP)

**AWS Resources:**

- S3 bucket: `ml-model-artifacts-<account-id>`
- IAM role: `<cluster-name>-kserve-irsa`
- IAM policy: `<cluster-name>-kserve-s3-read`

**Local Files:**

- `k8s/kserve/00-namespace-and-sa.yaml` – Auto-generated with correct IAM role
- `k8s/kserve/sklearn-deployment.yaml` – Auto-generated deployment manifest

For more details, see [`scripts/README.md`](scripts/README.md).

---

## 5. Manual Setup (If You Prefer Step-by-Step)

If you want to understand each step or can't use the automation scripts, here's the manual process.

**Note**: The automated scripts are strongly recommended as they handle all the complexity of IRSA configuration, init container setup, and proper environment variable configuration automatically.

### Apply Terraform

```bash
terraform init
terraform apply
```

### Get Terraform Outputs

```bash
# Get the IAM role ARN
terraform output kserve_irsa_role_arn
# Output: arn:aws:iam::268112029918:role/demo-cluster-kserve-irsa

# Get the S3 bucket name
terraform output kserve_model_bucket
# Output: ml-model-artifacts-268112029918
```

### Configure kubectl

```bash
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region $(terraform output -raw region)
```

### Create Kubernetes Manifests

The deployment requires careful configuration of IRSA credentials. Here's the minimal setup:

Create a folder: `k8s/kserve/` and add this file: **`00-namespace-and-sa.yaml`**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: kserve
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-sa
  namespace: kserve
  annotations:
    # Replace with your actual IAM role ARN from terraform output
    eks.amazonaws.com/role-arn: "arn:aws:iam::268112029918:role/demo-cluster-kserve-irsa"
```

Apply it:

```bash
kubectl apply -f k8s/kserve/00-namespace-and-sa.yaml
```

This connects the **Kubernetes** side to the **Terraform** side via IRSA.

### Important: No InferenceService CRDs

**This implementation does NOT install KServe CRDs or controllers.** Instead, it uses direct Kubernetes Deployments with KServe container images. This approach avoids webhook connectivity issues while maintaining ML model serving functionality.

If you need the full manual deployment manifest, refer to the generated `k8s/kserve/sklearn-deployment.yaml` file after running `setup-kserve-complete.sh`, which includes:

- Storage-initializer as init container with proper IRSA configuration
- KServe sklearn server as main container
- Correct environment variables and volume mounts
- Service definition

For most use cases, we recommend using the automation scripts rather than manual deployment.

---

## 6. Direct Deployment with KServe Containers

Since we're bypassing InferenceService CRDs due to EKS webhook limitations, we deploy KServe components as standard Kubernetes Deployments. The automation script handles this automatically, but here's what happens under the hood:

### Storage Initializer Pattern

The deployment uses a two-container pattern:

1. **Init Container**: `kserve/storage-initializer:v0.13.0` downloads the model from S3
2. **Main Container**: `kserve/sklearnserver:v0.13.0` serves inference requests

Both containers share an `emptyDir` volume at `/mnt/models`, and both have IRSA credentials configured via environment variables and projected service account tokens.

### Key Configuration Requirements

For IRSA to work correctly, the deployment must include:

```yaml
env:
  - name: AWS_ROLE_ARN
    value: "arn:aws:iam::268112029918:role/demo-cluster-kserve-irsa"
  - name: AWS_WEB_IDENTITY_TOKEN_FILE
    value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
  - name: AWS_REGION
    value: "us-east-2"
```

And the projected volume:

```yaml
volumes:
  - name: aws-iam-token
    projected:
      sources:
        - serviceAccountToken:
            path: token
            expirationSeconds: 86400
            audience: sts.amazonaws.com
```

### Applying the Deployment

The complete manifest is generated by `setup-kserve-complete.sh` and saved to `k8s/kserve/sklearn-deployment.yaml`. You can apply it with:

```bash
kubectl apply -f k8s/kserve/sklearn-deployment.yaml
```

This creates:

- A Deployment with init container (storage-initializer) and main container (sklearn server)
- A ClusterIP Service on port 80 → 8080
- Proper IRSA configuration for S3 access

The deployment typically becomes ready in under 1 minute.

---

## 7. Test the Model Serving Endpoint

Once the deployment is running, you can test it without any additional AWS costs (no ALB needed) using port-forwarding.

### Port-Forward to the Service

```bash
# Find the service
kubectl get svc -n kserve

# Port-forward to the sklearn-iris service
kubectl port-forward -n kserve service/sklearn-iris 8080:80
```

### Send a Test Request

In another terminal, send a prediction request:

```bash
curl -v \
  -H "Content-Type: application/json" \
  -d '{"instances": [[5.1, 3.5, 1.4, 0.2]]}' \
  http://localhost:8080/v1/models/sklearn-iris:predict
```

Expected response:

```json
{
  "predictions": [0]
}
```

This gives you a full "ML model served from EKS" experience **with no extra AWS costs** beyond the cluster itself.

### Verify IRSA Configuration

If you encounter S3 access issues, verify the IRSA setup:

```bash
# Verify ServiceAccount annotation
kubectl get sa kserve-sa -n kserve -o yaml | grep role-arn

# Check pod environment variables (should see AWS_ROLE_ARN)
kubectl get pods -n kserve
kubectl exec -n kserve <pod-name> -c kserve-container -- env | grep AWS

# Check storage-initializer logs (should show successful model download)
kubectl logs -n kserve <pod-name> -c storage-initializer
```

The storage-initializer should complete in under 1 second with logs showing the S3 download.

---

## 8. Repository Structure (Final Result)

After implementing everything, your repo structure looks like this:

```
demo-eks-cluster/
├── eks.tf                          # EKS cluster config (updated with 3 nodes)
├── vpc.tf                          # VPC config
├── kserve-irsa.tf                  # KServe IRSA root config (NEW)
├── variables.tf                    # Root variables
├── outputs.tf                      # Root outputs
├── versions.tf                     # Provider configuration
├── terraform.tfvars                # Variable values
├── README.md                       # Main documentation
├── DEPLOYMENT_SUMMARY.md           # Complete architecture guide (NEW)
├── INFRASTRUCTURE_REVIEW.md        # IaC audit documentation (NEW)
├── QUICK_REFERENCE.md              # Command cheat sheet (NEW)
├── modules/
│   └── aws/
│       ├── eks/v1/                 # EKS module
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   ├── versions.tf
│       │   └── README.md
│       ├── vpc/v1/                 # VPC module
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   ├── versions.tf
│       │   └── README.md
│       └── kserve-irsa/v1/         # KServe IRSA module (NEW)
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           ├── versions.tf
│           └── README.md
├── k8s/                            # Kubernetes manifests (NEW)
│   └── kserve/
│       ├── 00-namespace-and-sa.yaml
│       └── sklearn-deployment.yaml  # Generated by setup script
└── scripts/                        # Automation scripts (NEW)
    ├── setup-kserve-complete.sh
    ├── test-kserve-updated.sh
    ├── teardown-kserve.sh
    └── README.md
```

**Key Points:**

- **Modular design** – KServe IRSA follows the same pattern as EKS and VPC
- **Clean root config** – Only invokes modules, doesn't define resources
- **Automated scripts** – Generate deployment manifests with correct IRSA configuration
- **Self-documenting** – Each module and directory has its own README
- **Direct deployments** – Uses standard Kubernetes Deployments, not InferenceService CRDs

---

## 9. Cleanup (Important for Cost)

### Automated Cleanup

The easiest way to remove all KServe resources:

```bash
./scripts/teardown-kserve.sh
```

This script:

- Deletes the sklearn-iris deployment and service
- Removes the kserve namespace
- Cleans up generated manifest files

### Manual Terraform Cleanup

If you want to remove the Terraform-managed resources:

```bash
# Destroy only KServe IRSA resources
terraform destroy -target=module.kserve_irsa

# Or destroy everything (EKS cluster, VPC, all resources)
terraform destroy
```

### Optional S3 Cleanup

```bash
# Remove S3 bucket and contents (if you want to delete it)
aws s3 rb s3://ml-model-artifacts-<account-id> --force
```

**Note:** The IAM role and S3 bucket don't incur costs when not in use. You can keep them for future deployments.

---

## 10. Summary

### What We Built

- ✅ **Modular Terraform design** – New `kserve-irsa/v1` module following existing patterns
- ✅ **Clean root configuration** – Only ~60 lines that invoke the module
- ✅ **IRSA integration** – Secure S3 access without long-lived credentials
- ✅ **Direct Kubernetes Deployments** – Bypasses webhook limitations in EKS
- ✅ **Automation scripts** – One-command setup, testing, and teardown
- ✅ **Cost-effective testing** – Port-forward instead of ALB
- ✅ **Production-ready** – Follows HashiCorp and AWS best practices
- ✅ **Self-documented** – READMEs and comprehensive documentation

### Repository Files Added

**Terraform:**

- `kserve-irsa.tf` (root) – Invokes the KServe IRSA module
- `modules/aws/kserve-irsa/v1/` – Reusable IRSA module with all files

**Kubernetes:**

- `k8s/kserve/00-namespace-and-sa.yaml` – Namespace and service account with IRSA annotation
- `k8s/kserve/sklearn-deployment.yaml` – Generated deployment manifest (created by setup script)

**Automation:**

- `scripts/setup-kserve-complete.sh` – Automated deployment with IRSA configuration
- `scripts/test-kserve-updated.sh` – End-to-end testing with model training and inference
- `scripts/teardown-kserve.sh` – Clean resource removal
- `scripts/README.md` – Script documentation

**Documentation:**

- `DEPLOYMENT_SUMMARY.md` – Complete architecture and implementation guide
- `INFRASTRUCTURE_REVIEW.md` – IaC audit and configuration drift resolution
- `QUICK_REFERENCE.md` – Command cheat sheet
- Updated `README.md` – Main documentation with KServe additions

### Key Implementation Details

1. **Direct Deployments Approach** – Uses standard Kubernetes Deployments instead of InferenceService CRDs to avoid EKS webhook limitations
2. **Storage Initializer Pattern** – Init container downloads models from S3 before main container starts
3. **Explicit IRSA Configuration** – Environment variables and projected volumes configured manually in deployment manifests
4. **No External Dependencies** – No cert-manager, no Knative Serving, no Helm required
5. **Fast Deployment** – Typically completes in under 1 minute
6. **Proven Reliability** – Tested through multiple deployment cycles

### Architecture Decision: Why Direct Deployments?

In standard EKS networking configurations, the API server (in AWS-managed VPC) cannot reliably reach pod-based webhooks (in customer VPC). This affects KServe's mutating and validating webhooks. By using direct Kubernetes Deployments with explicit configuration:

- ✅ No webhook dependency
- ✅ Full control over init container configuration
- ✅ Same KServe container images and functionality
- ✅ Simpler architecture with fewer moving parts
- ✅ More transparent and debuggable

### Next Steps

You can now:

- **Deploy different models** – Modify the deployment manifest for TensorFlow, PyTorch, XGBoost, etc.
- **Add autoscaling** – Configure HPA for your Deployments
- **Add monitoring** – Deploy Prometheus and Grafana for observability
- **Production setup** – Add AWS Load Balancer Controller and Ingress for external access
- **Scale infrastructure** – Increase node count in `eks.tf` for higher workload capacity

### Resources

- [KServe Official Documentation](https://kserve.github.io/website/)
- [KServe Container Images](https://github.com/kserve/kserve/tree/master/python)
- [AWS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Terraform Module Best Practices](https://www.terraform.io/language/modules/develop)
- [Repository](https://github.com/Femi-lawal/demo-eks-cluster)

---

This implementation maintains the original repo philosophy: **AWS-first, Terraform IaC, modular and reusable**. The direct deployment approach provides a pragmatic solution to EKS limitations while delivering full ML model serving capabilities. You can integrate this into your existing EKS infrastructure as a production-ready ML serving layer.

---

## Wrapping Up

Congratulations! You've built a production-ready ML model serving platform on EKS using Infrastructure as Code principles.

**What makes this special:**

- 🎯 **Reproducible** – Anyone can recreate this environment with two commands
- 🔒 **Secure** – No AWS credentials hardcoded anywhere
- 📦 **Modular** – Easy to adapt for different models or frameworks
- 💰 **Cost-effective** – No unnecessary resources running
- 📚 **Well-documented** – Your team can understand and maintain it

### What's Next?

Now that you have the foundation, you can:

1. **Try different ML frameworks**

   - Replace `sklearnserver` with `torchserve` for PyTorch models
   - Use `tensorflow-serving` for TensorFlow models
   - Try `xgbserver` for XGBoost models

2. **Add production features**

   - Set up horizontal pod autoscaling (HPA)
   - Add Prometheus and Grafana for monitoring
   - Configure AWS Load Balancer Controller for external access
   - Implement A/B testing with multiple model versions

3. **Scale your infrastructure**
   - Increase node count in `eks.tf`
   - Add GPU nodes for deep learning models
   - Set up multi-region deployments

### Resources & Further Reading

- [KServe Official Docs](https://kserve.github.io/website/) - Deep dive into KServe capabilities
- [AWS IRSA Guide](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) - Official AWS documentation
- [Terraform Module Docs](https://www.terraform.io/language/modules/develop) - Best practices for module development
- [GitHub Repository](https://github.com/Femi-lawal/demo-eks-cluster) - Complete working code

### Got Questions?

Drop a comment below or reach out on [Twitter/X](https://twitter.com/your-handle). I'd love to hear about what you're building!

---

_This is part of the "Navigating AWS EKS with Terraform" series. Check out the other articles for more EKS best practices and real-world patterns._
