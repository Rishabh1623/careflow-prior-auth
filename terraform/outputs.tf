output "api_gateway_url" {
  description = "Base URL for the CareFlow API"
  value       = aws_apigatewayv2_stage.main.invoke_url
}

output "submit_endpoint" {
  description = "Full URL to submit a prior authorization request"
  value       = "${aws_apigatewayv2_stage.main.invoke_url}/submit"
}

output "submission_lambda_arn" {
  description = "ARN of the submission Lambda"
  value       = aws_lambda_function.submission.arn
}

output "orchestrator_lambda_arn" {
  description = "ARN of the durable orchestrator Lambda"
  value       = aws_lambda_function.orchestrator.arn
}

output "reviewer_callback_lambda_arn" {
  description = "ARN of the reviewer callback Lambda"
  value       = aws_lambda_function.reviewer_callback.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB requests table"
  value       = aws_dynamodb_table.requests.name
}

output "reviewer_sns_topic_arn" {
  description = "ARN of the reviewer notifications SNS topic"
  value       = aws_sns_topic.reviewer.arn
}

output "decision_sns_topic_arn" {
  description = "ARN of the decision notifications SNS topic"
  value       = aws_sns_topic.decisions.arn
}

output "anthropic_secret_arn" {
  description = "ARN of the Anthropic API key secret in Secrets Manager"
  value       = aws_secretsmanager_secret.anthropic_api_key.arn
  sensitive   = true
}

output "decision_date_index_name" {
  description = "Name of the GSI for querying decisions by type and date"
  value       = "DecisionDateIndex"
}

output "callback_idempotency_table_name" {
  description = "Name of the DynamoDB table used for callback idempotency"
  value       = aws_dynamodb_table.callback_idempotency.name
}

output "environment" {
  description = "Deployment environment"
  value       = var.environment
}

output "aws_region" {
  description = "AWS region where CareFlow is deployed"
  value       = var.aws_region
}

output "devops_agent_role_arn" {
  description = "ARN of the IAM role that AWS DevOps Agent assumes to monitor CareFlow"
  value       = aws_iam_role.devops_agent.arn
}
