#!/usr/bin/env bash
# Imports all existing CareFlow AWS resources into Terraform state.
# Run this after `terraform init` when state is empty but resources exist.
#
# Usage: ./scripts/terraform-import.sh [env]   (default: dev)
set -euo pipefail

ENV="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "==> CareFlow Terraform import — environment: $ENV"
cd "$TF_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────

import() {
  local addr="$1" id="$2"
  if terraform state show "$addr" &>/dev/null 2>&1; then
    echo "  SKIP  $addr (already in state)"
  else
    echo "  import $addr"
    terraform import "$addr" "$id"
  fi
}

aws_account() {
  aws sts get-caller-identity --query Account --output text
}

# ── Resolve dynamic IDs ───────────────────────────────────────────────────────

ACCOUNT=$(aws_account)
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
PREFIX="careflow-${ENV}"

echo "  account=$ACCOUNT  region=$REGION  prefix=$PREFIX"
echo ""

# API Gateway — ID is random, look it up by name
APIGW_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${PREFIX}-api'].ApiId | [0]" \
  --output text)
if [[ "$APIGW_ID" == "None" || -z "$APIGW_ID" ]]; then
  echo "ERROR: API Gateway '${PREFIX}-api' not found. Aborting." >&2
  exit 1
fi
echo "  api_gateway_id=$APIGW_ID"

# API Gateway integrations (keyed by target Lambda suffix)
apigw_integration_id() {
  local fn_name="$1"   # e.g. careflow-dev-submission
  local fn_arn="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${fn_name}"
  aws apigatewayv2 get-integrations \
    --api-id "$APIGW_ID" \
    --query "Items[?IntegrationUri=='${fn_arn}'].IntegrationId | [0]" \
    --output text
}

# API Gateway routes (keyed by route key substring)
apigw_route_id() {
  local route_key="$1"   # e.g. "POST /submit"
  aws apigatewayv2 get-routes \
    --api-id "$APIGW_ID" \
    --query "Items[?RouteKey=='${route_key}'].RouteId | [0]" \
    --output text
}

# SNS subscription ARN for a given topic and email endpoint
sns_subscription_arn() {
  local topic_arn="$1"
  local email="$2"
  aws sns list-subscriptions-by-topic \
    --topic-arn "$topic_arn" \
    --query "Subscriptions[?Endpoint=='${email}'].SubscriptionArn | [0]" \
    --output text
}

# Secrets Manager — ARN has a random suffix, resolve by name
secret_arn() {
  local name="$1"
  aws secretsmanager describe-secret \
    --secret-id "$name" \
    --query ARN \
    --output text 2>/dev/null || echo ""
}

secret_version_id() {
  local secret_arn="$1"
  aws secretsmanager list-secret-version-ids \
    --secret-id "$secret_arn" \
    --query "Versions[?contains(VersionStages,'AWSCURRENT')].VersionId | [0]" \
    --output text
}

# ── Read notification email from tfvars (needed for SNS subscription lookup) ─

NOTIFICATION_EMAIL=$(grep 'notification_email' "$TF_DIR/terraform.tfvars" \
  | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d '[:space:]')

# ── SNS topic ARNs (deterministic) ───────────────────────────────────────────

REVIEWER_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT}:${PREFIX}-reviewer-notifications"
DECISIONS_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT}:${PREFIX}-decision-notifications"

# ── Resolve dynamic lookup IDs ────────────────────────────────────────────────

echo "Resolving dynamic resource IDs..."

SUBMISSION_INTEGRATION_ID=$(apigw_integration_id "${PREFIX}-submission")
STATUS_INTEGRATION_ID=$(apigw_integration_id "${PREFIX}-status")
REVIEWER_INTEGRATION_ID=$(apigw_integration_id "${PREFIX}-reviewer-callback")

SUBMIT_ROUTE_ID=$(apigw_route_id "POST /submit")
STATUS_ROUTE_ID=$(apigw_route_id "GET /status/{request_id}")
REVIEW_ROUTE_ID=$(apigw_route_id "POST /review/{callback_id}")

REVIEWER_SUB_ARN=$(sns_subscription_arn "$REVIEWER_TOPIC_ARN" "$NOTIFICATION_EMAIL")
DECISIONS_SUB_ARN=$(sns_subscription_arn "$DECISIONS_TOPIC_ARN" "$NOTIFICATION_EMAIL")

SECRET_NAME="careflow/${ENV}/anthropic-api-key"
SECRET_ARN=$(secret_arn "$SECRET_NAME")
SECRET_VERSION_ID=$(secret_version_id "$SECRET_ARN")

echo ""
echo "Starting imports..."
echo ""

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────

import aws_cloudwatch_log_group.api_gateway       "/aws/apigateway/${PREFIX}"
import aws_cloudwatch_log_group.submission        "/aws/lambda/${PREFIX}-submission"
import aws_cloudwatch_log_group.orchestrator      "/aws/lambda/${PREFIX}-orchestrator"
import aws_cloudwatch_log_group.reviewer_callback "/aws/lambda/${PREFIX}-reviewer-callback"
import aws_cloudwatch_log_group.status            "/aws/lambda/${PREFIX}-status"

# ── DynamoDB ──────────────────────────────────────────────────────────────────

import aws_dynamodb_table.requests              "${PREFIX}-prior-auth-requests"
import aws_dynamodb_table.callback_idempotency  "${PREFIX}-callback-idempotency"

# ── IAM Roles ─────────────────────────────────────────────────────────────────

import aws_iam_role.submission        "${PREFIX}-submission-lambda-role"
import aws_iam_role.orchestrator      "${PREFIX}-orchestrator-lambda-role"
import aws_iam_role.reviewer_callback "${PREFIX}-reviewer-callback-lambda-role"
import aws_iam_role.status            "${PREFIX}-status-lambda-role"
import aws_iam_role.devops_agent      "${PREFIX}-devops-agent-role"

# ── IAM Role Policies (inline) ───────────────────────────────────────────────

import aws_iam_role_policy.submission        "${PREFIX}-submission-lambda-role:${PREFIX}-submission-policy"
import aws_iam_role_policy.orchestrator      "${PREFIX}-orchestrator-lambda-role:${PREFIX}-orchestrator-policy"
import aws_iam_role_policy.reviewer_callback "${PREFIX}-reviewer-callback-lambda-role:${PREFIX}-reviewer-callback-policy"
import aws_iam_role_policy.status            "${PREFIX}-status-lambda-role:${PREFIX}-status-policy"
import aws_iam_role_policy.devops_agent      "${PREFIX}-devops-agent-role:${PREFIX}-devops-agent-policy"

# ── IAM Role Policy Attachments ───────────────────────────────────────────────

BASIC_EXEC="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
DURABLE_EXEC="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicDurableExecutionRolePolicy"

import aws_iam_role_policy_attachment.submission_basic        "${PREFIX}-submission-lambda-role/${BASIC_EXEC}"
import aws_iam_role_policy_attachment.orchestrator_basic      "${PREFIX}-orchestrator-lambda-role/${BASIC_EXEC}"
import aws_iam_role_policy_attachment.orchestrator_durable    "${PREFIX}-orchestrator-lambda-role/${DURABLE_EXEC}"
import aws_iam_role_policy_attachment.reviewer_callback_basic "${PREFIX}-reviewer-callback-lambda-role/${BASIC_EXEC}"
import aws_iam_role_policy_attachment.status_basic            "${PREFIX}-status-lambda-role/${BASIC_EXEC}"

# ── Lambda Functions ──────────────────────────────────────────────────────────

import aws_lambda_function.submission        "${PREFIX}-submission"
import aws_lambda_function.orchestrator      "${PREFIX}-orchestrator"
import aws_lambda_function.reviewer_callback "${PREFIX}-reviewer-callback"
import aws_lambda_function.status            "${PREFIX}-status"

# ── Lambda Alias ──────────────────────────────────────────────────────────────

import aws_lambda_alias.orchestrator_live "${PREFIX}-orchestrator/live"

# ── Lambda Permissions ────────────────────────────────────────────────────────

import aws_lambda_permission.submission_apigw        "${PREFIX}-submission/AllowAPIGatewayInvoke"
import aws_lambda_permission.reviewer_callback_apigw "${PREFIX}-reviewer-callback/AllowAPIGatewayInvoke"
import aws_lambda_permission.status_apigw            "${PREFIX}-status/AllowAPIGatewayInvoke"

# ── API Gateway ───────────────────────────────────────────────────────────────

import aws_apigatewayv2_api.main   "$APIGW_ID"
import aws_apigatewayv2_stage.main "${APIGW_ID}/dev"

import aws_apigatewayv2_integration.submission        "${APIGW_ID}/${SUBMISSION_INTEGRATION_ID}"
import aws_apigatewayv2_integration.status            "${APIGW_ID}/${STATUS_INTEGRATION_ID}"
import aws_apigatewayv2_integration.reviewer_callback "${APIGW_ID}/${REVIEWER_INTEGRATION_ID}"

import aws_apigatewayv2_route.submission        "${APIGW_ID}/${SUBMIT_ROUTE_ID}"
import aws_apigatewayv2_route.status            "${APIGW_ID}/${STATUS_ROUTE_ID}"
import aws_apigatewayv2_route.reviewer_callback "${APIGW_ID}/${REVIEW_ROUTE_ID}"

# ── SNS ───────────────────────────────────────────────────────────────────────

import aws_sns_topic.reviewer  "$REVIEWER_TOPIC_ARN"
import aws_sns_topic.decisions "$DECISIONS_TOPIC_ARN"

import "aws_sns_topic_subscription.reviewer_email[0]"  "$REVIEWER_SUB_ARN"
import "aws_sns_topic_subscription.decisions_email[0]" "$DECISIONS_SUB_ARN"

# ── Secrets Manager ───────────────────────────────────────────────────────────

import aws_secretsmanager_secret.anthropic_api_key         "$SECRET_ARN"
import aws_secretsmanager_secret_version.anthropic_api_key "${SECRET_ARN}|${SECRET_VERSION_ID}"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "==> Import complete. Run 'terraform plan' to verify state is clean."
