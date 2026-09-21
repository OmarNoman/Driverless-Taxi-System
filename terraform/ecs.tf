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

resource "aws_cloudwatch_log_group" "redis" {
  name              = "/ecs/${var.project_name}-redis"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "mongo_secondary" {
  name              = "/ecs/${var.project_name}-mongo-secondary"
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
        { name = "POSTGRES_DB", value = "driverless_taxi" },
        # 6.4HD - read replica. Must match the CIDR enable-replication.sh writes into
        # pg_hba.conf.
        { name = "REPL_CIDR", value = var.vpc_cidr },
      ]
      # Resolved by ECS from SSM Parameter Store at container start (secrets.tf) - the
      # container still just sees plain POSTGRES_PASSWORD/REPL_PASSWORD env vars, no
      # image/app change.
      secrets = [
        { name = "POSTGRES_PASSWORD", valueFrom = aws_ssm_parameter.postgres_password.arn },
        { name = "REPL_PASSWORD", valueFrom = aws_ssm_parameter.postgres_replication_password.arn },
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

# --- Postgres read replica: real streaming replication, not a managed-service toggle
# (6.4HD). Same SGs and container port (5432) as the primary - per the shared networking
# fact, a second member listening on the primary's own container port needs no new
# security-group rule, only a new NLB listener on a different external port (5433). No
# manual init step needed (unlike the Mongo replica set): replica-entrypoint.sh runs
# pg_basebackup automatically on every container start. ---

resource "aws_cloudwatch_log_group" "postgres_replica" {
  name              = "/ecs/${var.project_name}-postgres-replica"
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "postgres_replica" {
  family                   = "${var.project_name}-postgres-replica"
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
      image        = "${aws_ecr_repository.postgres_seeded.repository_url}:week9-replica"
      essential    = true
      portMappings = [{ containerPort = 5432, protocol = "tcp" }]
      environment = [
        { name = "PRIMARY_HOST", value = aws_lb.internal.dns_name },
      ]
      secrets = [
        { name = "REPL_PASSWORD", valueFrom = aws_ssm_parameter.postgres_replication_password.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.postgres_replica.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "postgres-replica"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-postgres-replica"
  }
}

resource "aws_ecs_service" "postgres_replica" {
  name            = "${var.project_name}-postgres-replica"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.postgres_replica.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.database.id, aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.postgres_replica.arn
    container_name   = "postgres"
    container_port   = 5432
  }

  depends_on = [aws_lb_listener.postgres_replica]

  tags = {
    Name = "${var.project_name}-postgres-replica"
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
      name      = "mongo"
      image     = "${aws_ecr_repository.mongo_seeded.repository_url}:week8"
      essential = true
      # 6.4HD - replica set member. --bind_ip_all is needed because mongod defaults to
      # binding only 127.0.0.1 once --replSet is set.
      command      = ["mongod", "--replSet", "dtxrs", "--bind_ip_all"]
      portMappings = [{ containerPort = 27017, protocol = "tcp" }]
      environment = [
        { name = "HISTORY_TTL_DAYS", value = "7" },
        # SKIP_INIT=true - the official image's entrypoint runs init-telemetry.sh
        # against a TEMPORARY bootstrap instance that still inherits --replSet, and a
        # --replSet-configured node can never accept writes until rs.initiate() has run
        # against it (confirmed by hitting this directly - it crash-loops otherwise,
        # every restart, since Fargate's ephemeral storage means every primary restart
        # starts from an empty data directory). This defers schema setup entirely;
        # terraform/README.md's manual step re-runs the script afterwards as a one-off
        # task once this node is actually primary.
        { name = "SKIP_INIT", value = "true" },
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

# --- Mongo secondary: replica-set read scaling for `telemetry` (6.4HD) ---
#
# Same SGs and container port (27017) as the primary - per the shared networking fact,
# a second member listening on the primary's own container port needs no new
# security-group rule, only a new NLB listener on a different external port (27018)
# forwarding to a target group whose targets still register on 27017. rs.initiate() is a
# one-time manual admin action, not modelled here - see terraform/README.md.

resource "aws_ecs_task_definition" "mongo_secondary" {
  family                   = "${var.project_name}-mongo-secondary"
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
      image        = "${aws_ecr_repository.mongo_seeded.repository_url}:week9-secondary"
      essential    = true
      command      = ["mongod", "--replSet", "dtxrs", "--bind_ip_all"]
      portMappings = [{ containerPort = 27017, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mongo_secondary.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "mongo-secondary"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-mongo-secondary"
  }
}

resource "aws_ecs_service" "mongo_secondary" {
  name            = "${var.project_name}-mongo-secondary"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.mongo_secondary.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.database.id, aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mongo_secondary.arn
    container_name   = "mongo"
    container_port   = 27017
  }

  depends_on = [aws_lb_listener.mongo_secondary]

  tags = {
    Name = "${var.project_name}-mongo-secondary"
  }
}

# --- Redis: private subnet, cache-aside layer for dispatch-service (6.4HD), no persistence ---

resource "aws_ecs_task_definition" "redis" {
  family                   = "${var.project_name}-redis"
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
      name      = "redis"
      image     = "${aws_ecr_repository.redis.repository_url}:week9"
      essential = true
      # --maxmemory bounds memory since this is a pure cache with no eviction budget
      # otherwise; allkeys-lru is the right eviction policy for a cache-aside workload
      # where every key is equally disposable. No persistence flags needed - Fargate's
      # ephemeral storage is fine for a cache that's rebuilt from Postgres/Mongo on miss.
      command      = ["redis-server", "--maxmemory", "64mb", "--maxmemory-policy", "allkeys-lru"]
      portMappings = [{ containerPort = 6379, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.redis.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-redis"
  }
}

resource "aws_ecs_service" "redis" {
  name            = "${var.project_name}-redis"
  cluster         = aws_ecs_cluster.dtx.id
  task_definition = aws_ecs_task_definition.redis.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.database.id, aws_security_group.internal_services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.redis.arn
    container_name   = "redis"
    container_port   = 6379
  }

  depends_on = [aws_lb_listener.redis]

  tags = {
    Name = "${var.project_name}-redis"
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

  # Week 8c-iii: Application Auto Scaling (autoscaling.tf) changes the live desired
  # count directly via its own UpdateService calls, outside Terraform. Without this,
  # the next plan/apply would see that as drift and force desired_count back to the
  # literal 1 below, silently undoing an active scale-out.
  lifecycle {
    ignore_changes = [desired_count]
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

  # Week 8c-iii: Application Auto Scaling (autoscaling.tf) changes the live desired
  # count directly via its own UpdateService calls, outside Terraform. Without this,
  # the next plan/apply would see that as drift and force desired_count back to the
  # literal 1 below, silently undoing an active scale-out.
  lifecycle {
    ignore_changes = [desired_count]
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
        # 6.4HD - replica-set aware. dispatch-service is the system's only Mongo reader
        # (telemetry-service only writes, and writes always go to the primary regardless
        # of readPreference, so its own MONGO_URL is left untouched); secondaryPreferred
        # offloads availableCandidates()'s reads onto the secondary when it's healthy,
        # falling back to the primary otherwise.
        { name = "MONGO_URL", value = "mongodb://${aws_lb.internal.dns_name}:27017,${aws_lb.internal.dns_name}:27018/driverless_taxi?replicaSet=dtxrs&readPreference=secondaryPreferred" },
        { name = "REDIS_URL", value = "redis://${aws_lb.internal.dns_name}:6379" },
      ]
      # Resolved by ECS from SSM Parameter Store at container start (secrets.tf) - the
      # container still just sees plain PG_URL/PG_READ_URL env vars, no application code
      # change beyond store.js's optional pgReadUrl param (6.4HD).
      secrets = [
        { name = "PG_URL", valueFrom = aws_ssm_parameter.postgres_url.arn },
        { name = "PG_READ_URL", valueFrom = aws_ssm_parameter.postgres_read_url.arn },
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
