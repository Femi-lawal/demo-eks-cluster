terraform {
  required_version = "1.5.1"

  required_providers {
    aws = {
      version = ">= 5.40.0"
      source  = "hashicorp/aws"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.7"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0"
    }
  }

  backend "s3" {
    bucket         = ""
    key            = ""
    region         = ""
    dynamodb_table = ""
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.global_tags
  }
}
