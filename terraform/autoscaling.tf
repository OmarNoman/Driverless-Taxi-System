# Week 8c-iii: CloudWatch alarms + Application Auto Scaling.
#
# Plan (Solution Overview): "the Node.js microservices will utilize AWS auto scaling.
# The system will monitor the CPU utilization and message queue depth. If the queue of
# telemetry data exceeds a set threshold, then AWS will automatically spin up additional
# instances of the Telemetry and Event Router microservices to manage the load, then
# scaling back down when traffic subsides."
#
# Step Scaling + explicit CloudWatch alarms, not Target Tracking: the plan's own wording
# is threshold-crossing language ("exceeds a set threshold... scaling back down"), which
# maps directly onto "alarm breaches threshold -> step policy adds capacity" / "low-side
# alarm -> step policy removes capacity." Target Tracking has no predefined ECS metric
# for SQS depth - doing it "properly" needs a customized_metric_specification with
# metric-math (backlog-per-task), exactly the kind of derived/custom metric already
# avoided when choosing ApproximateNumberOfMessagesVisible in the first place (a plain,
# free, standard metric).
#
# Deliberate deviation from the plan's literal wording, documented here rather than
# silently built either way: event-router only ever WRITES to the SQS queue in AWS
# mode, it never reads from or drains it - only telemetry-service (the consumer) does.
# Scaling event-router on queue
# depth would not mechanically relieve a backed-up queue, so event-router gets a
# CPU-only trigger here; telemetry-service gets both CPU and queue depth.

resource "aws_appautoscaling_target" "event_router" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.dtx.name}/${aws_ecs_service.event_router.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 1
  max_capacity       = 3
}

resource "aws_appautoscaling_target" "telemetry_service" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.dtx.name}/${aws_ecs_service.telemetry_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 1
  max_capacity       = 3
}

# --- event-router: CPU only ---

resource "aws_appautoscaling_policy" "event_router_cpu_out" {
  name               = "${var.project_name}-event-router-cpu-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.event_router.service_namespace
  resource_id        = aws_appautoscaling_target.event_router.resource_id
  scalable_dimension = aws_appautoscaling_target.event_router.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "event_router_cpu_high" {
  alarm_name          = "${var.project_name}-event-router-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "event-router CPU above 70% for 2 minutes - scale out."
  dimensions = {
    ClusterName = aws_ecs_cluster.dtx.name
    ServiceName = aws_ecs_service.event_router.name
  }
  alarm_actions = [aws_appautoscaling_policy.event_router_cpu_out.arn]
}

resource "aws_appautoscaling_policy" "event_router_cpu_in" {
  name               = "${var.project_name}-event-router-cpu-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.event_router.service_namespace
  resource_id        = aws_appautoscaling_target.event_router.resource_id
  scalable_dimension = aws_appautoscaling_target.event_router.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "event_router_cpu_low" {
  alarm_name          = "${var.project_name}-event-router-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "event-router CPU below 30% for 3 minutes - scale in."
  dimensions = {
    ClusterName = aws_ecs_cluster.dtx.name
    ServiceName = aws_ecs_service.event_router.name
  }
  alarm_actions = [aws_appautoscaling_policy.event_router_cpu_in.arn]
}

# --- telemetry-service: CPU ---

resource "aws_appautoscaling_policy" "telemetry_service_cpu_out" {
  name               = "${var.project_name}-telemetry-service-cpu-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.telemetry_service.service_namespace
  resource_id        = aws_appautoscaling_target.telemetry_service.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_service.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_service_cpu_high" {
  alarm_name          = "${var.project_name}-telemetry-service-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "telemetry-service CPU above 70% for 2 minutes - scale out."
  dimensions = {
    ClusterName = aws_ecs_cluster.dtx.name
    ServiceName = aws_ecs_service.telemetry_service.name
  }
  alarm_actions = [aws_appautoscaling_policy.telemetry_service_cpu_out.arn]
}

resource "aws_appautoscaling_policy" "telemetry_service_cpu_in" {
  name               = "${var.project_name}-telemetry-service-cpu-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.telemetry_service.service_namespace
  resource_id        = aws_appautoscaling_target.telemetry_service.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_service.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_service_cpu_low" {
  alarm_name          = "${var.project_name}-telemetry-service-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "telemetry-service CPU below 30% for 3 minutes - scale in."
  dimensions = {
    ClusterName = aws_ecs_cluster.dtx.name
    ServiceName = aws_ecs_service.telemetry_service.name
  }
  alarm_actions = [aws_appautoscaling_policy.telemetry_service_cpu_in.arn]
}

# --- telemetry-service: SQS queue depth (the actual consumer of dtx-telemetry-queue) ---

resource "aws_appautoscaling_policy" "telemetry_service_sqs_out" {
  name               = "${var.project_name}-telemetry-service-sqs-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.telemetry_service.service_namespace
  resource_id        = aws_appautoscaling_target.telemetry_service.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_service.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_service_sqs_high" {
  alarm_name          = "${var.project_name}-telemetry-service-sqs-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 100
  alarm_description   = "dtx-telemetry-queue depth above 100 for 2 minutes - scale out."
  dimensions = {
    QueueName = aws_sqs_queue.telemetry.name
  }
  alarm_actions = [aws_appautoscaling_policy.telemetry_service_sqs_out.arn]
}

resource "aws_appautoscaling_policy" "telemetry_service_sqs_in" {
  name               = "${var.project_name}-telemetry-service-sqs-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.telemetry_service.service_namespace
  resource_id        = aws_appautoscaling_target.telemetry_service.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_service.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_service_sqs_low" {
  alarm_name          = "${var.project_name}-telemetry-service-sqs-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_description   = "dtx-telemetry-queue depth below 10 for 3 minutes - scale in."
  dimensions = {
    QueueName = aws_sqs_queue.telemetry.name
  }
  alarm_actions = [aws_appautoscaling_policy.telemetry_service_sqs_in.arn]
}
