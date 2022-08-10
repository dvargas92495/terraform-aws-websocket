terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 2.7.0"
    }
    github = {
      source = "integrations/github"
      version = ">= 4.2.0"
    }
  }
}

data "aws_caller_identity" "current" {}

variable "name" {
  type = string
}

variable "repo" {
  type = string
  default = ""
}

variable "paths" {
  type    = list
  default = []
}

locals {
  repo = length(var.repo) > 0 ? var.repo : replace(var.name, "-", ".")
}

resource "aws_apigatewayv2_api" "ws" {
  name                       = var.name
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  tags = {
    Application = var.name
  }
}

data "aws_iam_policy_document" "assume_lambda_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_execution_policy" {
  statement {
    actions = [
      "ses:sendEmail",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
      "s3:DeleteObject",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:CreateLogGroup"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "execute-api:Invoke"
    ]
    resources = [
      "arn:aws:execute-api:us-east-1:${data.aws_caller_identity.current.account_id}:${aws_apigatewayv2_api.ws.id}/production/POST/*"
    ]
  }

  statement {
    actions = [
      "execute-api:ManageConnections"
    ]
    resources = [
      "arn:aws:execute-api:us-east-1:${data.aws_caller_identity.current.account_id}:${aws_apigatewayv2_api.ws.id}/*"
    ]
  }

  statement {
    actions = [
      "sts:AssumeRole"
    ]
    resources = [
      "arn:aws:iam::*:role/${var.name}-lambda-ws-execution"
    ]
  }
}

resource "aws_iam_policy" "lambda_execution_policy" {
  name = "${var.name}-lambda-ws-execution"
  policy = data.aws_iam_policy_document.lambda_execution_policy.json
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.name}-lambda-ws-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_policy.json
  tags = {
    Application = var.name
  }
}

resource "aws_iam_role_policy_attachment" "lambda_role" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_execution_policy.arn
}

# lambda resource requires either filename or s3... wow
data "archive_file" "dummy" {
  type        = "zip"
  output_path = "./dummy.zip"

  source {
    content   = "// TODO IMPLEMENT"
    filename  = "dummy.js"
  }
}

resource "aws_lambda_function" "websocket_lambda" {
  for_each      = toset(var.paths)
  filename      = "dummy.zip"
  function_name = "${var.name}_ws_${each.value}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "ws_${each.value}.handler"
  runtime       = "nodejs16.x"
  timeout       = 10
  memory_size   = 5120
}

resource "aws_apigatewayv2_integration" "websocket_integration" {
  for_each         = toset(var.paths)
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"

  connection_type           = "INTERNET"
  content_handling_strategy = "CONVERT_TO_TEXT"
  integration_method        = "POST"
  integration_uri           = aws_lambda_function.websocket_lambda[each.value].invoke_arn
  passthrough_behavior      = "WHEN_NO_MATCH"
}

resource "aws_lambda_permission" "websocket_permission" {
  for_each      = toset(var.paths)
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.websocket_lambda[each.value].function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_apigatewayv2_route" "websocket_route" {
  for_each  = toset(var.paths)
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = replace(each.value, "/^on/", "$")
  target = "integrations/${aws_apigatewayv2_integration.websocket_integration[each.value].id}"
}

resource "aws_apigatewayv2_deployment" "ws" {
  api_id      = aws_apigatewayv2_api.ws.id
  description = "Latest Deployment"

  triggers = {
    redeployment = sha1(join(",", var.paths))
  }

  depends_on  = [
    aws_apigatewayv2_route.websocket_route
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_stage" "ws" {
  api_id = aws_apigatewayv2_api.ws.id
  name   = "production"
  deployment_id = aws_apigatewayv2_deployment.ws.id
  default_route_settings {
    logging_level = "INFO"
    throttling_burst_limit = 5000
    throttling_rate_limit = 10000
  }
}

data "aws_route53_zone" "zone" {
  name = join(".", reverse(slice(reverse(split(".", local.repo)), 0, 2)))
}

resource "aws_acm_certificate" "ws" {
  domain_name       = "ws.${local.repo}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "ws_cert" {
  name    = tolist(aws_acm_certificate.ws.domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.ws.domain_validation_options)[0].resource_record_type
  zone_id = data.aws_route53_zone.zone.id
  records = [tolist(aws_acm_certificate.ws.domain_validation_options)[0].resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "ws" {
  certificate_arn         = aws_acm_certificate.ws.arn
  validation_record_fqdns = [aws_route53_record.ws_cert.fqdn]
}

resource "aws_apigatewayv2_domain_name" "ws" {
  domain_name     = "ws.${local.repo}"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.ws.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_route53_record" "ws" {
  name    = aws_apigatewayv2_domain_name.ws.id
  type    = "A"
  zone_id = data.aws_route53_zone.zone.id

  alias {
    evaluate_target_health = true
    name                   = aws_apigatewayv2_domain_name.ws.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.ws.domain_name_configuration[0].hosted_zone_id
  }
}

resource "aws_apigatewayv2_api_mapping" "api" {
  count       = length(var.paths) > 0 ? 1 : 0
  api_id      = aws_apigatewayv2_api.ws.id
  stage       = aws_apigatewayv2_stage.ws.id
  domain_name = aws_apigatewayv2_domain_name.ws.id
}

resource "github_actions_secret" "web_socket_url" {
  repository       = local.repo
  secret_name      = "WEB_SOCKET_URL"
  plaintext_value  = aws_apigatewayv2_stage.ws.invoke_url
}

resource "github_actions_secret" "api_gateway_id" {
  repository       = local.repo
  secret_name      = "API_GATEWAY_ID"
  plaintext_value  = aws_apigatewayv2_api.ws.id
}
