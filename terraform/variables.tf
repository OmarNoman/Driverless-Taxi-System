variable "aws_region" {
  description = "AWS region. AWS Academy Learner Lab is normally locked to us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to tag and name every resource."
  type        = string
  default     = "dtx"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Number of availability zones to spread subnets across. Defaults to 1: subnets,
    route tables and security groups are free regardless of AZ count, but each of the
    3 interface VPC endpoints bills per-AZ (about $0.01/hr per AZ it's attached to), and
    this environment is torn down after every test session rather than left running for
    real HA to matter. Bump to 2 for a single line change if a multi-AZ demonstration
    is needed for the report.
  EOT
  type        = number
  default     = 1
}
