terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.25.0"
    }
  }

  backend "s3" {
    bucket = "careflow-terraform-state"
    key    = "careflow-prior-auth/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "careflow-${var.environment}"

  common_tags = {
    Project     = "CareFlow"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
