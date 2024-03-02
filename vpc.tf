module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "demo-vpc"
  cidr = local.cidr

  azs             = local.aws_availability_zones
  private_subnets = [for key, value in local.aws_availability_zones : cidrsubnet(local.cidr, 4, key)]
  public_subnets  = [for key, value in local.aws_availability_zones : cidrsubnet(local.cidr, 8, key + 48)]

  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_vpn_gateway      = false
  enable_dns_hostnames    = true
  map_public_ip_on_launch = false

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  aws_availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr                   = "10.0.0.0/16"
}
