data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ── Submission Lambda ──────────────────────────────────────────────────────────

resource "aws_iam_role" "submission" {
  name               = "${local.name_prefix}-submission-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "submission_basic" {
  role       = aws_iam_role.submission.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "submission" {
  statement {
    sid       = "DynamoDBWrite"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.requests.arn]
  }

  statement {
    sid       = "InvokeOrchestrator"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_alias.orchestrator_live.arn]
  }

  statement {
    sid       = "KMSDynamoDB"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.dynamodb.arn]
  }
}

resource "aws_iam_role_policy" "submission" {
  name   = "${local.name_prefix}-submission-policy"
  role   = aws_iam_role.submission.id
  policy = data.aws_iam_policy_document.submission.json
}

# ── Orchestrator Lambda ────────────────────────────────────────────────────────

resource "aws_iam_role" "orchestrator" {
  name               = "${local.name_prefix}-orchestrator-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "orchestrator_basic" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "orchestrator_durable" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicDurableExecutionRolePolicy"
}

data "aws_iam_policy_document" "orchestrator" {
  statement {
    sid     = "DynamoDBReadWrite"
    effect  = "Allow"
    actions = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.requests.arn]
  }

  statement {
    sid     = "SNSPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    resources = [
      aws_sns_topic.reviewer.arn,
      aws_sns_topic.decisions.arn,
    ]
  }

  statement {
    sid     = "SecretsManagerGetKey"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:careflow/${var.environment}/anthropic-api-key*",
    ]
  }

  # Durable SDK re-invokes the function itself to continue checkpointed execution
  statement {
    sid     = "DurableSelfInvoke"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction", "lambda:GetFunction"]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.name_prefix}-orchestrator*",
    ]
  }

  # Feature 6: Publish per-decision cost metrics to CloudWatch
  statement {
    sid       = "CloudWatchPutMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid       = "KMSDynamoDB"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.dynamodb.arn]
  }
}

resource "aws_iam_role_policy" "orchestrator" {
  name   = "${local.name_prefix}-orchestrator-policy"
  role   = aws_iam_role.orchestrator.id
  policy = data.aws_iam_policy_document.orchestrator.json
}

# ── Reviewer Callback Lambda ───────────────────────────────────────────────────

resource "aws_iam_role" "reviewer_callback" {
  name               = "${local.name_prefix}-reviewer-callback-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "reviewer_callback_basic" {
  role       = aws_iam_role.reviewer_callback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "reviewer_callback" {
  statement {
    sid    = "ResolveDurableCallback"
    effect = "Allow"
    actions = [
      "lambda:SendDurableExecutionCallbackSuccess",
      "lambda:SendDurableExecutionCallbackFailure",
    ]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.name_prefix}-orchestrator*",
    ]
  }

  statement {
    sid       = "DynamoDBUpdate"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.requests.arn]
  }

  # Feature 4: Atomic idempotency check — claim callback_id before resolving
  statement {
    sid       = "IdempotencyTableWrite"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.callback_idempotency.arn]
  }

  statement {
    sid       = "KMSDynamoDB"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.dynamodb.arn]
  }
}

resource "aws_iam_role_policy" "reviewer_callback" {
  name   = "${local.name_prefix}-reviewer-callback-policy"
  role   = aws_iam_role.reviewer_callback.id
  policy = data.aws_iam_policy_document.reviewer_callback.json
}

# ── Status Lambda ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "status" {
  name               = "${local.name_prefix}-status-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "status_basic" {
  role       = aws_iam_role.status.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "status" {
  statement {
    sid       = "DynamoDBGetItem"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.requests.arn]
  }

  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.dynamodb.arn]
  }
}

resource "aws_iam_role_policy" "status" {
  name   = "${local.name_prefix}-status-policy"
  role   = aws_iam_role.status.id
  policy = data.aws_iam_policy_document.status.json
}

# ── Secrets Manager — Anthropic API Key ───────────────────────────────────────

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name        = "careflow/${var.environment}/anthropic-api-key"
  description = "Anthropic API key for CareFlow orchestrator Lambda"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "anthropic_api_key" {
  secret_id     = aws_secretsmanager_secret.anthropic_api_key.id
  secret_string = var.anthropic_api_key
}
