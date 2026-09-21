output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "mosquitto_security_group_id" {
  value = aws_security_group.mosquitto.id
}

output "internal_services_security_group_id" {
  value = aws_security_group.internal_services.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}

output "ecr_repository_urls" {
  description = "Push targets for the manual image pushes and for the ECS task definitions."
  value = {
    event_router      = aws_ecr_repository.event_router.repository_url
    telemetry_service = aws_ecr_repository.telemetry_service.repository_url
    dispatch_service  = aws_ecr_repository.dispatch_service.repository_url
    postgres_seeded   = aws_ecr_repository.postgres_seeded.repository_url
    mongo_seeded      = aws_ecr_repository.mongo_seeded.repository_url
    redis             = aws_ecr_repository.redis.repository_url
  }
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.dtx.name
}

output "sqs_queue_url" {
  value = aws_sqs_queue.telemetry.url
}

output "sqs_dlq_url" {
  value = aws_sqs_queue.telemetry_dlq.url
}

output "vpc_link_security_group_id" {
  description = "For Week 8c's API Gateway VPC Link."
  value       = aws_security_group.vpc_link.id
}

output "internal_nlb_dns_name" {
  description = "Internal service discovery (Cloud Map is blocked in this Academy account, see nlb.tf). Also Week 8c's API Gateway VPC Link target, via aws_lb_target_group.dispatch_service."
  value       = aws_lb.internal.dns_name
}

output "http_api_invoke_url" {
  description = "Public entry point for dispatch-service's 3 routes (GET /health, GET /nodes, POST /rides), via API Gateway HTTP API + VPC Link -> internal NLB -> dispatch-service. Week 8c."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "autoscaling_target_resource_ids" {
  description = "For aws application-autoscaling describe-scalable-targets verification. Week 8c-iii."
  value = {
    event_router      = aws_appautoscaling_target.event_router.resource_id
    telemetry_service = aws_appautoscaling_target.telemetry_service.resource_id
  }
}

output "mongo_replica_members" {
  description = "6.4HD - the two host:port pairs to pass as rs.initiate()'s member identities (terraform/README.md). Must be the NLB's real routable addresses, since that's what dispatch-service's MONGO_URL and every other client reach Mongo through."
  value = [
    "${aws_lb.internal.dns_name}:27017",
    "${aws_lb.internal.dns_name}:27018",
  ]
}

output "cloudwatch_alarm_names" {
  description = "For aws cloudwatch describe-alarms verification and forcing a demo scale-out/in. Week 8c-iii."
  value = [
    aws_cloudwatch_metric_alarm.event_router_cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.event_router_cpu_low.alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_service_cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_service_cpu_low.alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_service_sqs_high.alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_service_sqs_low.alarm_name,
  ]
}
