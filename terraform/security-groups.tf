resource "aws_security_group" "mosquitto" {
  name        = "${var.project_name}-mosquitto-sg"
  description = "Public MQTT broker (decision #5: MQTT is exposed in the public subnet)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "MQTT from any vehicle/simulator"
    from_port   = 1883
    to_port     = 1883
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-mosquitto-sg"
  }
}

# event-router and telemetry-service never listen on a port (pure MQTT/SQS consumers).
# dispatch-service listens on 8080, reachable only from the API Gateway VPC Link
# (Week 8c) - this is exactly the ingress rule Week 7 deferred until something real was
# running behind it.
resource "aws_security_group" "internal_services" {
  name        = "${var.project_name}-internal-services-sg"
  description = "event-router, telemetry-service, dispatch-service"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "dispatch-service HTTP from the API Gateway VPC Link"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }

  # The internal NLB's (nlb.tf) own health-check probes for "ip" targets originate from
  # the load balancer's own ENIs in the VPC, not from any container carrying a security
  # group of ours, so the security-group-referenced rule above never matches them. Found
  # by hitting it directly: dispatch-service's target stayed "unhealthy" purely because
  # of this, even though the container itself was fine.
  ingress {
    description = "dispatch-service HTTP from the internal NLB health checks"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-internal-services-sg"
  }
}

# Used by the API Gateway VPC Link's own ENIs (Week 8c). No ingress needed here, it's
# the caller reaching into internal_services, not something else calling it.
resource "aws_security_group" "vpc_link" {
  name        = "${var.project_name}-vpc-link-sg"
  description = "API Gateway VPC Link (Week 8c) reaching dispatch-service"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-vpc-link-sg"
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-database-sg"
  description = "postgres + mongo, reachable only from the internal services"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from internal services"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.internal_services.id]
  }

  ingress {
    description     = "MongoDB from internal services"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.internal_services.id]
  }

  # Same NLB-health-check gap as internal_services above: the load balancer's own
  # health-check probes don't carry any of our security groups, so without this,
  # postgres/mongo's targets stay permanently "unhealthy" even when the containers
  # themselves are fine.
  ingress {
    description = "Postgres from the internal NLB health checks"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "MongoDB from the internal NLB health checks"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-database-sg"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "Interface VPC endpoints (ECR API/DKR, CloudWatch Logs), reachable only from the internal services"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from internal services"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.internal_services.id]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-vpc-endpoints-sg"
  }
}
