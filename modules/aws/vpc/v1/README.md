# Custom VPC Module for AWS EKS

This Terraform module creates a custom Virtual Private Cloud (VPC) designed to support an AWS Elastic Kubernetes Service (EKS) cluster. The module provisions public and private subnets, a NAT Gateway (optional), and configures route tables for optimal networking within an EKS environment.

## Prerequisites

- Terraform v1.5.1
- AWS provider v5.20.0

## Module Variables

| Name                             | Description                                                          | Type          | Default       |
| -------------------------------- | -------------------------------------------------------------------- | ------------- | ------------- |
| `nat_gateway`                    | Deploy NAT Gateway.                                                  | `bool`        | `false`       |
| `vpc_name`                       | Name of the VPC.                                                     | `string`      |               |
| `cidr_block`                     | The IPv4 CIDR block for the VPC.                                     | `string`      | `10.0.0.0/16` |
| `enable_dns_support`             | Enable/disable DNS support in the VPC.                               | `bool`        | `true`        |
| `enable_dns_hostnames`           | Enable/disable DNS hostnames in the VPC.                             | `bool`        | `false`       |
| `default_tags`                   | A map of tags to add to all resources.                               | `map(string)` | `{}`          |
| `subnet_public_count`            | Number of Public subnets.                                            | `number`      | `3`           |
| `subnet_public_additional_bits`  | Additional bits with which to extend the prefix for public subnets.  | `number`      | `4`           |
| `subnet_public_tags`             | Tags to add to all public subnets.                                   | `map(string)` | `{}`          |
| `subnet_private_count`           | Number of Private subnets.                                           | `number`      | `3`           |
| `subnet_private_additional_bits` | Additional bits with which to extend the prefix for private subnets. | `number`      | `4`           |
| `subnet_private_tags`            | Tags to add to all private subnets.                                  | `map(string)` | `{}`          |

## Outputs

| Name                       | Description                          |
| -------------------------- | ------------------------------------ |
| `aws_vpc`                  | The created VPC.                     |
| `subnets_public`           | Public subnets within the VPC.       |
| `subnets_private`          | Private subnets within the VPC.      |
| `aws_internet_gateway`     | The Internet Gateway for the VPC.    |
| `aws_route_table_public`   | The ID of the public route table.    |
| `aws_route_table_private`  | The ID of the private route table.   |
| `nat_gateway_ipv4_address` | The IPv4 address of the NAT Gateway. |

## Example Usage

```hcl
module "custom_vpc" {
  source = "./modules/aws/vpc/v1"

  nat_gateway              = true
  vpc_name                 = "demo-vpc"
  cidr_block               = "10.0.0.0/16"
  enable_dns_support       = true
  enable_dns_hostnames     = true
  default_tags             = {
                               Environment = "dev"
                             }
  subnet_public_count      = 3
  subnet_public_additional_bits = 4
  subnet_public_tags       = {
                               Tier = "public"
                             }
  subnet_private_count     = 3
  subnet_private_additional_bits = 4
  subnet_private_tags      = {
                               Tier = "private"
                             }
}
```
