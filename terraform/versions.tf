terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state only. Solo student project, no team to coordinate with, and this
  # environment gets built and torn down repeatedly (build, test, destroy, rebuild on
  # interview day) rather than kept running, so an S3 + DynamoDB remote backend would
  # only add cost and complexity with no real benefit here.
  backend "local" {
    path = "terraform.tfstate"
  }
}
