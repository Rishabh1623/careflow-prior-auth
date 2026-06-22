#!/usr/bin/env bash
# Sets up AWS DevOps Agent for CareFlow Prior Authorization Engine.
# Run once after `terraform apply` completes.
# Idempotent: re-running skips creation if the Agent Space already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT/terraform"

# Read config from Terraform outputs
REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
ENV=$(terraform output -raw environment)
AGENT_ROLE_ARN=$(terraform output -raw devops_agent_role_arn)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SPACE_NAME="CareFlow-PriorAuth-${ENV}"

echo "==> AWS DevOps Agent setup for CareFlow"
echo "    Region:     $REGION"
echo "    Account:    $ACCOUNT_ID"
echo "    Env:        $ENV"
echo "    Space name: $SPACE_NAME"
echo "    Agent role: $AGENT_ROLE_ARN"
echo ""

# ── 1. Create Agent Space (or reuse existing) ──────────────────────────────────

EXISTING_ID=$(aws devops-agent list-agent-spaces \
  --query "agentSpaces[?name=='${SPACE_NAME}'].agentSpaceId | [0]" \
  --output text \
  --region "$REGION" 2>/dev/null || true)

if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "None" ]]; then
  echo "==> Agent Space already exists — reusing: $EXISTING_ID"
  SPACE_ID="$EXISTING_ID"
else
  echo "==> Creating Agent Space..."
  SPACE_ID=$(aws devops-agent create-agent-space \
    --name "$SPACE_NAME" \
    --description "CareFlow AI Prior Authorization Engine. Monitors submission, orchestrator, and reviewer-callback Lambdas; DynamoDB request and idempotency tables; API Gateway; SNS topics; CloudWatch CareFlow metrics; and X-Ray traces." \
    --locale "en" \
    --tags "Project=CareFlow,Environment=${ENV},ManagedBy=Terraform" \
    --query 'agentSpace.agentSpaceId' \
    --output text \
    --region "$REGION")
  echo "==> Agent Space created: $SPACE_ID"
fi

# ── 2. Associate AWS account (monitor role) ────────────────────────────────────

echo "==> Associating AWS account with Agent Space..."
aws devops-agent associate-service \
  --agent-space-id "$SPACE_ID" \
  --service-id "aws" \
  --configuration "{
    \"aws\": {
      \"assumableRoleArn\": \"${AGENT_ROLE_ARN}\",
      \"accountId\": \"${ACCOUNT_ID}\",
      \"accountType\": \"monitor\"
    }
  }" \
  --region "$REGION"

echo "==> Association created."

# ── 3. Validate associations ───────────────────────────────────────────────────

echo "==> Validating AWS associations..."
aws devops-agent validate-aws-associations \
  --agent-space-id "$SPACE_ID" \
  --region "$REGION"

echo ""
echo "==> AWS DevOps Agent configured successfully"
echo ""
echo "    Agent Space ID : $SPACE_ID"
echo "    Console        : https://console.aws.amazon.com/devops-agent/home?region=${REGION}#/spaces/${SPACE_ID}"
echo ""
echo "DevOps Agent now monitors:"
echo "  Lambda  : careflow-${ENV}-submission"
echo "            careflow-${ENV}-orchestrator"
echo "            careflow-${ENV}-reviewer-callback"
echo "  DynamoDB: careflow-prior-auth-requests (+ DecisionDateIndex GSI)"
echo "            careflow-callback-idempotency"
echo "  API GW  : CareFlow HTTP API"
echo "  SNS     : careflow-${ENV}-reviewer-notifications"
echo "            careflow-${ENV}-decision-notifications"
echo "  CW      : Namespace CareFlow / CareFlowTokenCost metric"
echo "  X-Ray   : end-to-end Lambda trace chain"
