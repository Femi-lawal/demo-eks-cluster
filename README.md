# Terraform EKS Cluster Deployment

This repository contains Terraform configurations for deploying an Amazon EKS (Elastic Kubernetes Service) cluster and associated VPC (Virtual Private Cloud) infrastructure in AWS. It leverages modular design principles to separate the VPC and EKS configurations for clarity and reusability.

## Resources Created

The Terraform code sets up the following AWS resources:

- **VPC:**
  - VPC with specified CIDR block.
  - Public and private subnets across multiple availability zones.
  - Internet Gateway for public subnets.
  - Route tables and associations for subnets.
  - NAT Gateway for private subnets.
- **EKS Cluster:**
  - EKS cluster with specified Kubernetes version.
  - Managed node groups for running Kubernetes workloads.
  - Security groups for control plane and worker nodes
  - KMS Key for encryption of EKS cluster secrets.
  - Necessary IAM roles and policies for EKS operation.
  - An EKS Admins role for other users to assume to get access to the EKS
  - A Config Map for AWS Auth in EKS

## Prerequisites

- AWS Account and AWS CLI configured on your machine.
- Terraform v1.5.1 or higher.
- An S3 bucket and DynamoDB table for Terraform state management (see `terraform.tf`).

## Usage

1. **Clone the Repository**

   ```bash
   git clone https://github.com/Femi-lawal/demo-eks-cluster.git
   cd demo-eks-cluster
   ```

2. **Initialize Terraform**

   Initialize Terraform to download necessary providers and modules.

   ```bash
   terraform init
   ```

3. **Create a `terraform.tfvars` File (Optional)**

   Create a `terraform.tfvars` file to override default variable values. Example:

   ```hcl
   region                     = "eu-west-1"
   cluster_name               = "my-demo-cluster"
   aws_account_number         = "123456789"
   ```

4. **Setup Backend (Optional)**

   You can create a DynamoDB table and S3 bucket and provide their values to the backend block inside the terraform block in `terraform.tf`

   ```bash
   backend "s3" {
    bucket         = "s3-bucket-name"
    key            = "path-to-store-key-in-s3/terraform.tfstate"
    dynamodb_table = "dynamodb-table-name-for-state-locking"
    region         = "region-your-resources-were-provisioned"
    encrypt        = true
   }
   ```

   You can also just delete the backend block to keep state management local.

5. **Plan the Deployment**

   Review the actions Terraform will perform.

   ```bash
   terraform plan
   ```

6. **Apply the Configuration**

   Deploy your infrastructure.

   ```bash
   terraform apply
   ```

   Confirm the action by typing `yes` when prompted.

## Infrastructure Details

- **VPC (`vpc.tf`):** Configures a VPC named `demo-vpc` with specified CIDR block, and sets up both public and private subnets across three availability zones. NAT Gateway is enabled for outbound internet access from private subnets.

- **EKS Cluster (`eks.tf`):** Deploys an EKS cluster within the created VPC, utilizing the private subnets for the managed node groups. The node groups are configured with specified instance types and scaling parameters.

- **Variables (`variables.tf`):** Defines input variables for the Terraform configurations, including AWS region, cluster name, and settings for the S3 backend.

- **Terraform Backend (`terraform.tf`):** Configures the Terraform backend to use an S3 bucket for state storage and a DynamoDB table for state locking.

## Notes

- Ensure the S3 bucket and DynamoDB table specified in `terraform.tf` exist before initializing Terraform.
- Modify the `variables.tf` file as per your requirements or use a `terraform.tfvars` file for custom configurations.
- Review AWS costs associated with the resources created by these configurations.

## Cleanup

```bash
terraform destroy
```

Confirm the action by typing `yes` when prompted.
