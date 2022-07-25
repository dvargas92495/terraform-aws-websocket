data "aws_caller_identity" "current" {}

variable "name" {
  type = string
}

variable "repo" {
  type = string
  default = ""
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

resource "aws_lambda_function" "onconnect" {
  filename      = "dummy.zip"
  function_name = "${var.name}_onconnect"
  role          = aws_iam_role.lambda_role.arn
  handler       = "onconnect.handler"
  runtime       = "nodejs16.x"
  timeout       = 10
}

resource "aws_apigatewayv2_integration" "onconnect" {
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"

  connection_type           = "INTERNET"
  content_handling_strategy = "CONVERT_TO_TEXT"
  integration_method        = "POST"
  integration_uri           = aws_lambda_function.onconnect.invoke_arn
  passthrough_behavior      = "WHEN_NO_MATCH"
}

resource "aws_lambda_permission" "onconnect" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.onconnect.function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_apigatewayv2_route" "onconnect" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$connect"
  target = "integrations/${aws_apigatewayv2_integration.onconnect.id}"
}

resource "aws_lambda_function" "ondisconnect" {
  filename      = "dummy.zip"
  function_name = "${var.name}_ondisconnect"
  role          = aws_iam_role.lambda_role.arn
  handler       = "ondisconnect.handler"
  runtime       = "nodejs16.x"
  timeout       = 10
}

resource "aws_apigatewayv2_integration" "ondisconnect" {
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"

  connection_type           = "INTERNET"
  content_handling_strategy = "CONVERT_TO_TEXT"
  integration_method        = "POST"
  integration_uri           = aws_lambda_function.ondisconnect.invoke_arn
  passthrough_behavior      = "WHEN_NO_MATCH"
}

resource "aws_lambda_permission" "ondisconnect" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ondisconnect.function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_apigatewayv2_route" "ondisconnect" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$disconnect"
  target = "integrations/${aws_apigatewayv2_integration.ondisconnect.id}"
}

resource "aws_lambda_function" "sendmessage" {
  filename      = "dummy.zip"
  function_name = "${var.name}_sendmessage"
  role          = aws_iam_role.lambda_role.arn
  handler       = "sendmessage.handler"
  runtime       = "nodejs16.x"
  timeout       = 10
  memory_size   = 5120
}

resource "aws_apigatewayv2_integration" "sendmessage" {
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"

  connection_type           = "INTERNET"
  content_handling_strategy = "CONVERT_TO_TEXT"
  integration_method        = "POST"
  integration_uri           = aws_lambda_function.sendmessage.invoke_arn
  passthrough_behavior      = "WHEN_NO_MATCH"
}

resource "aws_lambda_permission" "sendmessage" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sendmessage.function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_apigatewayv2_route" "sendmessage" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "sendmessage"
  target = "integrations/${aws_apigatewayv2_integration.sendmessage.id}"
}

resource "aws_apigatewayv2_deployment" "ws" {
  api_id      = aws_apigatewayv2_api.ws.id
  description = "Latest Deployment"

  triggers = {
    redeployment = sha1(join(",", [
      jsonencode(aws_apigatewayv2_integration.onconnect),
      jsonencode(aws_apigatewayv2_route.onconnect),
      jsonencode(aws_apigatewayv2_integration.ondisconnect),
      jsonencode(aws_apigatewayv2_route.ondisconnect),
      jsonencode(aws_apigatewayv2_integration.sendmessage),
      jsonencode(aws_apigatewayv2_route.sendmessage),
    ]))
  }

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
