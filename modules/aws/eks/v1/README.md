# Amazon EKS Terraform Module

This module creates an Amazon EKS (Elastic Kubernetes Service) cluster with managed node groups on AWS.

## Prerequisites

- Terraform v1.5.1
- AWS provider version 5.20.0
- Kubernetes provider version 2.26.0

## Inputs

| Name                    | Description                                                                                            | Type           | Default      |
| ----------------------- | ------------------------------------------------------------------------------------------------------ | -------------- | ------------ |
| `region`                | AWS region                                                                                             | `string`       |              |
| `vpc_id`                | VPC ID                                                                                                 | `string`       |              |
| `cluster_name`          | Name of the EKS cluster                                                                                | `string`       |              |
| `public_subnets`        | Public Subnet IDs for the EKS cluster                                                                  | `list(string)` |              |
| `private_subnets`       | Private Subnet IDs for the EKS cluster                                                                 | `list(string)` |              |
| `default_ami_type`      | The type of AMI to use for the node group. Valid values: `AL2_x86_64`, `AL2_x86_64_GPU`                | `string`       | `AL2_x86_64` |
| `default_capacity_type` | The capacity type for the node group. Valid values: `ON_DEMAND`, `SPOT`                                | `string`       | `SPOT`       |
| `managed_node_groups`   | Configuration for managed node groups. Each group specifies name, instance types, and scaling settings | `map(object)`  | `{}`         |
| `cluster_addons`        | List of strings specifying cluster addons                                                              |

## Outputs

| Name                        | Description                                          |
| --------------------------- | ---------------------------------------------------- |
| `cluster_id`                | The ID of the created EKS cluster                    |
| `cluster_endpoint`          | The endpoint for your Kubernetes API server          |
| `cluster_security_group_id` | TThe security group id of the cluster                |
| `node_group_role_arn`       | The ARN of the IAM role used by the node group(s)    |
| `cluster_admins_role`       | The ARN of the role for EKS cluster admins to assume |

## Usage

Example to create an EKS cluster with a managed node group:

```hcl
module "eks" {
  source = "./modules/aws/eks/v2"

  region       = "eu-west-1"
  cluster_name = "my-eks-cluster"
  subnets      = ["subnet-xxxxxx", "subnet-yyyyyy", "subnet-zzzzzz"]
  vpc_id       = "vpc-xxxxxxx"

  managed_node_groups = {
    example_group = {
      name           = "example-node-group"
      desired_size   = 2
      min_size       = 1
      max_size       = 3
      instance_types = ["t3.large"]
    }
  }

  tags = {
    Environment = "development"
    Project     = "Kubernetes"
  }
}
```
