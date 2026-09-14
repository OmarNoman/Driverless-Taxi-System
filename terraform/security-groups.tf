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

# No ingress rule yet, on purpose. event-router and telemetry-service never listen on a
# port (pure MQTT consumers). dispatch-service listens on 8080, but the right ingress
# source (a VPC Link/NLB, or an ALB in front of API Gateway's integration) depends on
# how Week 8 actually fronts it - guessing that now would just mean redoing it once
# something real is running behind it.
resource "aws_security_group" "internal_services" {
  name        = "${var.project_name}-internal-services-sg"
  description = "event-router, telemetry-service, dispatch-service (no ingress rule until Week 8)"
  vpc_id      = aws_vpc.main.id

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
