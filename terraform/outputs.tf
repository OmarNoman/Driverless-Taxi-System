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
  description = "Push targets for Week 7's manual image push, and for Week 8's task definitions."
  value = {
    event_router      = aws_ecr_repository.event_router.repository_url
    telemetry_service = aws_ecr_repository.telemetry_service.repository_url
    dispatch_service  = aws_ecr_repository.dispatch_service.repository_url
  }
}
