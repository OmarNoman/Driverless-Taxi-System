# One repository per Node.js service, plus (Week 8) one per custom-seeded database
# image. Mosquitto gets none - it pulls eclipse-mosquitto:2 straight from Docker Hub
# since it lives in the public subnet with direct internet egress via the Internet
# Gateway.
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

resource "aws_ecr_repository" "postgres_seeded" {
  name                 = "${var.project_name}-postgres-seeded"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-postgres-seeded"
  }
}

resource "aws_ecr_repository" "mongo_seeded" {
  name                 = "${var.project_name}-mongo-seeded"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-mongo-seeded"
  }
}

# 6.4HD - Redis cache-aside layer in front of dispatch-service's vehicle-lookup query.
resource "aws_ecr_repository" "redis" {
  name                 = "${var.project_name}-redis"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-redis"
  }
}
