# Credentials come only from the environment (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_SESSION_TOKEN - the AWS Academy Learner Lab issues temporary STS credentials that
# expire after a few hours). Never hardcode credentials in any .tf file.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "sit314-driverless-taxi"
      Week      = "8c"
      ManagedBy = "terraform"
    }
  }
}
