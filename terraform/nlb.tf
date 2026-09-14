# Internal service discovery, via a Network Load Balancer, not AWS Cloud Map.
#
# Cloud Map (both the classic Service Discovery private-DNS-namespace form and the
# newer ECS Service Connect HTTP-namespace form) turned out to be entirely blocked in
# this AWS Academy Learner Lab account - "voclabs" gets AccessDeniedException on both
# servicediscovery:CreatePrivateDnsNamespace and servicediscovery:CreateHttpNamespace,
# confirmed by testing both directly. Standard ELB permissions are far more likely to
# be allowed (ALB/NLB are core, commonly-taught AWS services), and an NLB's DNS name is
# a real Terraform-known resource attribute the moment the LB exists, unlike a Cloud Map
# service ARN under Service Connect, which Terraform can never see.
#
# One internal NLB, one listener/target group per backend port. ECS's native
# `load_balancer` block on each service (in ecs.tf) registers/deregisters that
# service's task IP with its target group automatically as tasks start and stop - no
# Cloud Map, no manual IP wiring. NLB preserves the original client IP by default for
# IP-type targets, so the existing security-group rules (e.g. database-sg accepting
# 5432 "from internal_services") keep working unchanged, traffic arriving at the
# target still carries the real caller's security-group identity, not the NLB's.

resource "aws_lb" "internal" {
  name               = "${var.project_name}-internal-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-internal-nlb"
  }
}

resource "aws_lb_target_group" "postgres" {
  name        = "${var.project_name}-postgres-tg"
  port        = 5432
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-postgres-tg"
  }
}

resource "aws_lb_listener" "postgres" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 5432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.postgres.arn
  }
}

resource "aws_lb_target_group" "mongo" {
  name        = "${var.project_name}-mongo-tg"
  port        = 27017
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-mongo-tg"
  }
}

resource "aws_lb_listener" "mongo" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 27017
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mongo.arn
  }
}

resource "aws_lb_target_group" "mosquitto" {
  name        = "${var.project_name}-mosquitto-tg"
  port        = 1883
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-mosquitto-tg"
  }
}

resource "aws_lb_listener" "mosquitto" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 1883
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mosquitto.arn
  }
}

# Registered now so the target group exists ready for Week 8c's API Gateway VPC Link
# (a VPC Link can target an NLB directly), even though nothing calls dispatch-service
# through this NLB until then.
resource "aws_lb_target_group" "dispatch_service" {
  name        = "${var.project_name}-dispatch-tg"
  port        = 8080
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-dispatch-tg"
  }
}

resource "aws_lb_listener" "dispatch_service" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 8080
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dispatch_service.arn
  }
}
