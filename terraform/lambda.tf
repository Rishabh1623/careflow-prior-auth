resource "aws_lambda_function" "submission" {
  function_name    = "${local.name_prefix}-submission"
  runtime          = "python3.13"
  handler          = "handler.handler"
  role             = aws_iam_role.submission.arn
  filename         = "${path.module}/../build/submission.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/submission.zip")
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      DYNAMODB_TABLE             = aws_dynamodb_table.requests.name
      ORCHESTRATOR_FUNCTION_NAME = aws_lambda_function.orchestrator.function_name
    }
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.submission_basic]
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${local.name_prefix}-orchestrator"
  runtime          = "python3.13"
  handler          = "handler.handler"
  role             = aws_iam_role.orchestrator.arn
  filename         = "${path.module}/../build/orchestrator.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/orchestrator.zip")
  timeout          = 900
  memory_size      = 512

  environment {
    variables = {
      DYNAMODB_TABLE         = aws_dynamodb_table.requests.name
      REVIEWER_SNS_TOPIC_ARN = aws_sns_topic.reviewer.arn
      DECISION_SNS_TOPIC_ARN = aws_sns_topic.decisions.arn
    }
  }

  durable_config {
    execution_timeout = "P365D"
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.orchestrator_basic]
}

resource "aws_lambda_function" "reviewer_callback" {
  function_name    = "${local.name_prefix}-reviewer-callback"
  runtime          = "python3.13"
  handler          = "handler.handler"
  role             = aws_iam_role.reviewer_callback.arn
  filename         = "${path.module}/../build/reviewer_callback.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/reviewer_callback.zip")
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.requests.name
    }
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.reviewer_callback_basic]
}

# CloudWatch Log Groups with explicit retention
resource "aws_cloudwatch_log_group" "submission" {
  name              = "/aws/lambda/${local.name_prefix}-submission"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "orchestrator" {
  name              = "/aws/lambda/${local.name_prefix}-orchestrator"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "reviewer_callback" {
  name              = "/aws/lambda/${local.name_prefix}-reviewer-callback"
  retention_in_days = 14
  tags              = local.common_tags
}
