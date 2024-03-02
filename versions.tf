terraform {
  required_version = "1.5.1"

  required_providers {
    aws = {
      version = "5.20.0"
      source  = "hashicorp/aws"
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
