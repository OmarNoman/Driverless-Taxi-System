# One repository per Node.js service. Mosquitto gets none - it pulls eclipse-mosquitto:2
# straight from Docker Hub since it lives in the public subnet with direct internet
# egress via the Internet Gateway.
#
# force_delete = true matters: without it, terraform destroy fails on any repo that
# still holds an image, which would break the mandatory every-session teardown.

resource "aws_ecr_repository" "event_router" {
  name                 = "${var.project_name}-event-router"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-event-router"
  }
}

resource "aws_ecr_repository" "telemetry_service" {
  name                 = "${var.project_name}-telemetry-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-telemetry-service"
  }
}

resource "aws_ecr_repository" "dispatch_service" {
  name                 = "${var.project_name}-dispatch-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-dispatch-service"
  }
}
