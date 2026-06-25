resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "CareFlow Prior Authorization API"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = var.environment
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = local.common_tags
}

# ── POST /submit — Submission Lambda ──────────────────────────────────────────

resource "aws_apigatewayv2_integration" "submission" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.submission.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "submission" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /submit"
  target    = "integrations/${aws_apigatewayv2_integration.submission.id}"
}

resource "aws_lambda_permission" "submission_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.submission.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ── GET /status/{request_id} — Status Lambda ──────────────────────────────────

resource "aws_apigatewayv2_integration" "status" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.status.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /status/{request_id}"
  target    = "integrations/${aws_apigatewayv2_integration.status.id}"
}

resource "aws_lambda_permission" "status_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ── POST /review/{callback_id} — Reviewer Callback Lambda ─────────────────────

resource "aws_apigatewayv2_integration" "reviewer_callback" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.reviewer_callback.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "reviewer_callback" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /review/{callback_id+}"
  target    = "integrations/${aws_apigatewayv2_integration.reviewer_callback.id}"
}

resource "aws_lambda_permission" "reviewer_callback_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reviewer_callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
