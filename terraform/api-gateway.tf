# Week 8c: public HTTP API + VPC Link fronting dispatch-service.
#
# This is a public regional HTTP API (not a PRIVATE endpoint type), so it runs on
# AWS-managed infrastructure outside the VPC - no execute-api VPC endpoint is needed for
# that (a private-API endpoint is only for calling a PRIVATE API from inside a VPC). The
# VPC Link's own ENIs sit in the private subnets and reach the internal NLB over the
# VPC's local route; that path is already open via the vpc_link and internal_services
# security groups (security-groups.tf), wired up back in Week 7/8b specifically for this.
#
# Three explicit routes, not a single ANY /{proxy+}: dispatch-service has exactly 3
# routes and no path parameters (services/dispatch-service/src/index.js), so an
# unrecognized method/path is rejected at the API Gateway edge instead of being
# forwarded through. All three share one HTTP_PROXY integration targeting the NLB
# listener (a VPC Link integration must target a listener ARN, not a target group ARN
# directly).

resource "aws_apigatewayv2_vpc_link" "dispatch" {
  name               = "${var.project_name}-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-vpc-link"
  }
}

resource "aws_apigatewayv2_api" "dispatch" {
  name          = "${var.project_name}-http-api"
  protocol_type = "HTTP"

  tags = {
    Name = "${var.project_name}-http-api"
  }
}

resource "aws_apigatewayv2_integration" "dispatch" {
  api_id             = aws_apigatewayv2_api.dispatch.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.dispatch.id
  integration_uri    = aws_lb_listener.dispatch_service.arn
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.dispatch.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.dispatch.id}"
}

resource "aws_apigatewayv2_route" "nodes" {
  api_id    = aws_apigatewayv2_api.dispatch.id
  route_key = "GET /nodes"
  target    = "integrations/${aws_apigatewayv2_integration.dispatch.id}"
}

resource "aws_apigatewayv2_route" "rides" {
  api_id    = aws_apigatewayv2_api.dispatch.id
  route_key = "POST /rides"
  target    = "integrations/${aws_apigatewayv2_integration.dispatch.id}"
}

# $default auto-deploy stage, not a named stage: no CI/CD or staged-rollout requirement
# anywhere in the plan, and this project's whole AWS lifecycle is apply-verify-destroy
# in one sitting.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.dispatch.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name = "${var.project_name}-http-api-default-stage"
  }
}
