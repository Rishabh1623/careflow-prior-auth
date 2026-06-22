# IAM role that AWS DevOps Agent assumes to monitor CareFlow resources.
# After `terraform apply`, run scripts/setup_devops_agent.sh to create
# the Agent Space and associate this account.

data "aws_iam_policy_document" "devops_agent_trust" {
  statement {
    sid     = "AllowDevOpsAgentAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    # Required by DevOps Agent: prevents confused deputy attacks
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "devops_agent" {
  name               = "${local.name_prefix}-devops-agent-role"
  description        = "Role assumed by AWS DevOps Agent to monitor CareFlow resources"
  assume_role_policy = data.aws_iam_policy_document.devops_agent_trust.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "devops_agent_permissions" {
  # Lambda — read function configs and event source mappings
  statement {
    sid    = "LambdaReadOnly"
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:ListFunctions",
      "lambda:ListEventSourceMappings",
      "lambda:GetPolicy",
    ]
    resources = ["*"]
  }

  # DynamoDB — read table state and items for incident diagnosis
  statement {
    sid    = "DynamoDBReadOnly"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:ListTables",
      "dynamodb:DescribeGlobalTableSettings",
      "dynamodb:ListGlobalTables",
    ]
    resources = ["*"]
  }

  # API Gateway — inspect route and integration configuration
  statement {
    sid       = "APIGatewayReadOnly"
    effect    = "Allow"
    actions   = ["apigateway:GET"]
    resources = ["arn:aws:apigateway:${var.aws_region}::/*"]
  }

  # SNS — read topic and subscription state
  statement {
    sid    = "SNSReadOnly"
    effect = "Allow"
    actions = [
      "sns:GetTopicAttributes",
      "sns:ListTopics",
      "sns:ListSubscriptions",
      "sns:ListSubscriptionsByTopic",
    ]
    resources = ["*"]
  }

  # CloudWatch — metrics, alarms, and custom CareFlow namespace
  statement {
    sid    = "CloudWatchReadOnly"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmsForMetric",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs — Lambda structured logs and Insights queries
  statement {
    sid    = "CloudWatchLogsReadOnly"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:DescribeQueries",
    ]
    resources = ["*"]
  }

  # X-Ray — distributed traces across the Lambda chain
  statement {
    sid    = "XRayReadOnly"
    effect = "Allow"
    actions = [
      "xray:GetTraceSummaries",
      "xray:BatchGetTraces",
      "xray:GetServiceGraph",
      "xray:GetTraceGraph",
      "xray:GetGroups",
      "xray:GetGroup",
      "xray:GetInsightSummaries",
    ]
    resources = ["*"]
  }

  # Secrets Manager — describe (not read) secrets for inventory visibility
  statement {
    sid    = "SecretsManagerDescribeOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "devops_agent" {
  name   = "${local.name_prefix}-devops-agent-policy"
  role   = aws_iam_role.devops_agent.id
  policy = data.aws_iam_policy_document.devops_agent_permissions.json
}
