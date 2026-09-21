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

  # Cross-zone load balancing is off by default for NLBs. Since az_count went from 1
  # to 2 for the API Gateway VPC Link (Week 8c-i), this NLB now has one node per AZ,
  # but every backend service here runs exactly 1 task, landing in only one AZ - with
  # cross-zone off, the other AZ's node has zero local healthy targets, so roughly half
  # of all requests (whichever happen to route via the "empty" AZ) fail. Confirmed
  # directly: a 30-request burst against the API Gateway -> VPC Link -> this NLB ->
  # dispatch-service path showed a persistent ~50% failure rate with no convergence,
  # while the target itself was independently confirmed healthy the whole time.
  enable_cross_zone_load_balancing = true

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

# 6.4HD - PostgreSQL read replica. External port 5433, but the target group's own port
# is still 5432 - the container port the replica's task actually registers on (ecs.tf),
# same pattern as the Mongo secondary.
resource "aws_lb_target_group" "postgres_replica" {
  name        = "${var.project_name}-postgres-replica-tg"
  port        = 5432
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-postgres-replica-tg"
  }
}

resource "aws_lb_listener" "postgres_replica" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 5433
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.postgres_replica.arn
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

# 6.4HD - MongoDB replica-set secondary. External port 27018, but the target group's own
# port is still 27017 - that's the container port the secondary's task actually
# registers on (ecs.tf), per the shared networking fact that a same-port second member
# needs no new security-group rule, only a new listener + target group.
resource "aws_lb_target_group" "mongo_secondary" {
  name        = "${var.project_name}-mongo-secondary-tg"
  port        = 27017
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-mongo-secondary-tg"
  }
}

resource "aws_lb_listener" "mongo_secondary" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 27018
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mongo_secondary.arn
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

# 6.4HD - Redis cache-aside layer in front of dispatch-service's vehicle-lookup query.
resource "aws_lb_target_group" "redis" {
  name        = "${var.project_name}-redis-tg"
  port        = 6379
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  tags = {
    Name = "${var.project_name}-redis-tg"
  }
}

resource "aws_lb_listener" "redis" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 6379
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.redis.arn
  }
}
