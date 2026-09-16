# Container Insights left disabled (default): the standard AWS/ECS CPUUtilization/
# MemoryUtilization metrics needed for the auto-scaling policy in Week 8c are already
# emitted for free at 1-minute resolution without it, and Container Insights bills per
# custom metric for something this project doesn't need.
resource "aws_ecs_cluster" "dtx" {
  name = "${var.project_name}-cluster"

  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# retention_in_days = 1: this environment is torn down every session, no reason to pay
# for (or risk the never-expire default of) longer log retention.
resource "aws_cloudwatch_log_group" "event_router" {
  name              = "/ecs/${var.project_name}-event-router"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "telemetry_service" {
  name              = "/ecs/${var.project_name}-telemetry-service"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "dispatch_service" {
  name              = "/ecs/${var.project_name}-dispatch-service"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "postgres" {
  name              = "/ecs/${var.project_name}-postgres"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "mongo" {
  name              = "/ecs/${var.project_name}-mongo"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "mosquitto" {
  name              = "/ecs/${var.project_name}-mosquitto"
  retention_in_days = 1
}

# --- Mosquitto: public subnet, pulls eclipse-mosquitto:2 straight from Docker Hub ---

resource "aws_ecs_task_definition" "mosquitto" {
  family                   = "${var.project_name}-mosquitto"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Stock image, no custom Dockerfile/ECR repo needed - it reaches Docker Hub directly
  # via this task's public IP. The official image's entrypoint execs a non-"mosquitto"-
  # prefixed command verbatim, so a minimal anonymous-listener config is written at
  # container start instead of baking one into an image. persistence off: Fargate's
  # local storage is ephemeral anyway (no EFS, by design), and every client here
  # reconnects and re-subscribes on its own.
  container_definitions = jsonencode([
    {
      name      = "mosquitto"
      image     = "eclipse-mosquitto:2"
      essential = true
      command = [
        "sh", "-c",
        "printf 'listener 1883\\nallow_anonymous true\\npersistence false\\nlog_dest stdout\\n' > /mosquitto/config/mosquitto.conf && exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf"
      ]
      portMappings = [{ containerPort = 1883, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mosquitto.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "mosquitto"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-mosquitto"
  }
}

resource "aws_ecs_service" "mosquitto" {
  name            = "${var.project_name}-mosquitto"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.mosquitto.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets = aws_subnet.public[*].id
    # mosquitto (its own 1883 listener) + internal_services (reused, NOT for its own
    # traffic, but because the logs VPC endpoint has private_dns_enabled = true, which
    # overrides logs.us-east-1.amazonaws.com to resolve to the endpoint's private IP for
    # every resource in the VPC, public subnet included. The endpoint's security group
    # only accepts 443 from internal_services, so without this Mosquitto's awslogs
    # driver can reach a CloudWatch hostname that silently resolves to an address it has
    # no security-group path to, and the task fails to start with a "connection issue
    # between the task and Amazon CloudWatch" error. Confirmed by hitting this directly.
    security_groups  = [aws_security_group.mosquitto.id, aws_security_group.internal_services.id]
    assign_public_ip = true
  }

  # Internal discovery via the NLB (nlb.tf), not Cloud Map (blocked in this Academy
  # account). Mosquitto still keeps its own direct public IP above for external vehicle
  # simulators; this registration is only for the other services reaching it privately.
  load_balancer {
    target_group_arn = aws_lb_target_group.mosquitto.arn
    container_name   = "mosquitto"
    container_port   = 1883
  }

  depends_on = [aws_lb_listener.mosquitto]

  tags = {
    Name = "${var.project_name}-mosquitto"
  }
}

# --- Postgres: private subnet, custom-seeded image, ephemeral storage ---

resource "aws_ecs_task_definition" "postgres" {
  family                   = "${var.project_name}-postgres"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "postgres"
      image        = "${aws_ecr_repository.postgres_seeded.repository_url}:week8"
      essential    = true
      portMappings = [{ containerPort = 5432, protocol = "tcp" }]
      environment = [
        { name = "POSTGRES_USER", value = "dtx" },
        { name = "POSTGRES_PASSWORD", value = "dtx_dev_pw" },
        { name = "POSTGRES_DB", value = "driverless_taxi" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.postgres.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "postgres"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

resource "aws_ecs_service" "postgres" {
  name            = "${var.project_name}-postgres"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.postgres.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets = aws_subnet.private[*].id
    # database (accepts 5432 from internal_services) + internal_services (reused so this
    # task can reach the ecr.api/ecr.dkr VPC endpoints to pull its own image, with zero
    # new security-group rules needed - Fargate allows multiple SGs per ENI).
    security_groups  = [aws_security_group.database.id, aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.postgres.arn
    container_name   = "postgres"
    container_port   = 5432
  }

  depends_on = [aws_lb_listener.postgres]

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

# --- Mongo: private subnet, custom-seeded image, ephemeral storage ---

resource "aws_ecs_task_definition" "mongo" {
  family                   = "${var.project_name}-mongo"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "mongo"
      image        = "${aws_ecr_repository.mongo_seeded.repository_url}:week8"
      essential    = true
      portMappings = [{ containerPort = 27017, protocol = "tcp" }]
      environment = [
        { name = "HISTORY_TTL_DAYS", value = "7" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mongo.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "mongo"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-mongo"
  }
}

resource "aws_ecs_service" "mongo" {
  name            = "${var.project_name}-mongo"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.mongo.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.database.id, aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mongo.arn
    container_name   = "mongo"
    container_port   = 27017
  }

  depends_on = [aws_lb_listener.mongo]

  tags = {
    Name = "${var.project_name}-mongo"
  }
}

# --- event-router: private subnet, no inbound port, SQS-enabled ---

resource "aws_ecs_task_definition" "event_router" {
  family                   = "${var.project_name}-event-router"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "event-router"
      image     = "${aws_ecr_repository.event_router.repository_url}:week8"
      essential = true
      environment = [
        { name = "MQTT_URL", value = "mqtt://${aws_lb.internal.dns_name}:1883" },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.telemetry.url },
        # Fargate does not auto-inject AWS_REGION the way Lambda does - without this the
        # @aws-sdk/client-sqs client fails at startup with "Region is missing".
        { name = "AWS_REGION", value = var.aws_region },
        # Week 8c-ii: a shared subscription, not a plain one. Plain MQTT fans every
        # message out to every subscriber, so scaling this service past 1 instance
        # (Week 8c-iii) would have every instance process every packet - duplicate SQS
        # sends, duplicate telemetry_history writes, not a load split. $share/ makes
        # the broker split delivery across instances instead. Requires zero app code
        # change: TOPIC_IN is already an env var (services/event-router/src/index.js),
        # used only as the subscribe() filter - the message handler still receives the
        # real publish topic (e.g. fleet/TAXI-001/telemetry), unaffected by the $share/
        # prefix, so downstream vehicleID parsing is unchanged.
        { name = "TOPIC_IN", value = "$share/event-router/fleet/+/telemetry" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.event_router.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "event-router"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-event-router"
  }
}

resource "aws_ecs_service" "event_router" {
  name            = "${var.project_name}-event-router"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.event_router.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  tags = {
    Name = "${var.project_name}-event-router"
  }
}

# --- telemetry-service: private subnet, no inbound port, SQS-enabled ---

resource "aws_ecs_task_definition" "telemetry_service" {
  family                   = "${var.project_name}-telemetry-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "telemetry-service"
      image     = "${aws_ecr_repository.telemetry_service.repository_url}:week8"
      essential = true
      environment = [
        { name = "MONGO_URL", value = "mongodb://${aws_lb.internal.dns_name}:27017" },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.telemetry.url },
        { name = "AWS_REGION", value = var.aws_region },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.telemetry_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "telemetry-service"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-telemetry-service"
  }
}

resource "aws_ecs_service" "telemetry_service" {
  name            = "${var.project_name}-telemetry-service"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.telemetry_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  tags = {
    Name = "${var.project_name}-telemetry-service"
  }
}

# --- dispatch-service: private subnet, port 8080, reached via the Week 8c API Gateway ---

resource "aws_ecs_task_definition" "dispatch_service" {
  family                   = "${var.project_name}-dispatch-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.lab_role.arn
  task_role_arn            = data.aws_iam_role.lab_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "dispatch-service"
      image        = "${aws_ecr_repository.dispatch_service.repository_url}:week8"
      essential    = true
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "HTTP_PORT", value = "8080" },
        { name = "MQTT_URL", value = "mqtt://${aws_lb.internal.dns_name}:1883" },
        { name = "PG_URL", value = "postgresql://dtx:dtx_dev_pw@${aws_lb.internal.dns_name}:5432/driverless_taxi" },
        { name = "MONGO_URL", value = "mongodb://${aws_lb.internal.dns_name}:27017" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.dispatch_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "dispatch-service"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-dispatch-service"
  }
}

resource "aws_ecs_service" "dispatch_service" {
  name            = "${var.project_name}-dispatch-service"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.dispatch_service.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  # Not consumed by anything until Week 8c's API Gateway VPC Link targets this same
  # target group, registered now since the NLB/target group already exist this week.
  load_balancer {
    target_group_arn = aws_lb_target_group.dispatch_service.arn
    container_name   = "dispatch-service"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.dispatch_service]

  tags = {
    Name = "${var.project_name}-dispatch-service"
  }
}
