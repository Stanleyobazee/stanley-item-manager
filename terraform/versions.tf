terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Partial backend config on purpose — the bucket name must be globally unique to your
  # AWS account, so it can't be hardcoded here. Supply the rest at `terraform init` time:
  #   terraform init -backend-config="bucket=<your-bucket-name>" -backend-config="region=<your-region>"
  # See README.md "State backend setup" for creating the bucket first.
  backend "s3" {
    key = "item-manager-eks/terraform.tfstate"
  }
}
