# CareFlow Prior Authorization Engine

## Project Overview

CareFlow automates healthcare prior authorization decisions using AWS Lambda Durable Functions
and Anthropic Claude (`claude-sonnet-4-6`, `temperature=0`). Requests are auto-approved/denied
by AI or escalated to a human reviewer at zero compute cost while suspended.

## Architecture

| Component | Technology | Purpose |
|---|---|---|
| Submission Lambda | Python 3.13, boto3 | API entry point, request persistence |
| Orchestrator Lambda | Python 3.13, Durable SDK, Anthropic | Stateful workflow, Claude evaluation |
| Reviewer Callback Lambda | Python 3.13, boto3 | Human review resolution |
| DynamoDB | `careflow-prior-auth-requests` | Request state with 90-day TTL |
| SNS (reviewer) | `careflow-{env}-reviewer-notifications` | Human review alerts |
| SNS (decisions) | `careflow-{env}-decision-notifications` | Final decision event bus |
| Secrets Manager | `careflow/anthropic-api-key` | Anthropic API key |
| API Gateway | HTTP API v2 | Public REST endpoints |

## Stack

- Runtime: Python 3.13
- AI: Anthropic Claude API (`claude-sonnet-4-6`), `temperature=0` for determinism
- Orchestration: AWS Lambda Durable Functions (`aws-durable-execution-sdk-python`)
- Infrastructure: Terraform >= 1.5.0, AWS provider `~> 5.0`
- Storage: DynamoDB `PAY_PER_REQUEST`, 90-day TTL on `ttl` attribute (Unix epoch)
- Messaging: SNS dual-topic pattern (reviewer alerts / decision events)

## Orchestration Flow

```
POST /submit
  → Submission Lambda
      → DynamoDB PutItem (status=PENDING, ttl=now+90d)
      → invoke Orchestrator async (InvocationType=Event)
      → 202 { request_id }

Orchestrator (durable — checkpointed steps):
  1. fetch_request(request_id)         — DynamoDB GetItem
  2. get_api_key()                     — Secrets Manager
  3. evaluate_with_claude(request)     — Claude API

  if decision ∈ {approve, deny}:
    4. save_decision(...)              — DynamoDB UpdateItem (APPROVED|DENIED)
    5. notify_decision(...)            — SNS decisions topic
    → DONE

  if decision == escalate:
    4. callback = create_callback("human-review")
    5. notify_reviewer(callback_id, ...) — DynamoDB (UNDER_REVIEW) + SNS reviewer topic
    6. callback.result()               — SUSPEND (zero compute cost)

    [Human POSTs to POST /review/{callback_id}]
    → Reviewer Callback Lambda
        → send_durable_execution_callback_success(CallbackId, Result)
    → Orchestrator RESUMES

    7. save_review_decision(...)       — DynamoDB UpdateItem (APPROVED|DENIED + reviewer fields)
    8. notify_final_decision(...)      — SNS decisions topic
    → DONE
```

## DynamoDB Schema

Table: `careflow-prior-auth-requests`  
PK: `request_id` (String, UUID v4)

| Attribute | Type | Notes |
|---|---|---|
| request_id | S | UUID v4 |
| patient_id | S | |
| provider_id | S | |
| diagnosis_code | S | ICD-10 |
| procedure_code | S | CPT |
| status | S | PENDING / APPROVED / DENIED / UNDER_REVIEW |
| created_at | S | ISO 8601 UTC |
| updated_at | S | ISO 8601 UTC |
| ttl | N | Unix epoch seconds (90 days from creation) |
| claude_decision | S | approve / deny / escalate |
| claude_reasoning | S | Claude explanation |
| claude_confidence | S | Stored as string (avoids decimal.Inexact) |
| criteria_met | L | List of strings |
| criteria_failed | L | List of strings |
| callback_id | S | Set when escalated |
| reviewer_decision | S | approved / denied (set after human review) |
| reviewer_notes | S | |
| reviewer_id | S | |

## Durable SDK — Mandatory Rules

```python
from aws_durable_execution_sdk import (
    durable_execution, durable_step, DurableContext, StepContext,
)

@durable_step
def my_step(ctx: StepContext, arg: str) -> str:
    # All boto3 and Anthropic client instantiation goes HERE
    client = boto3.client("dynamodb")
    return client.get_item(...)

@durable_execution
def handler(event: dict, context: DurableContext) -> dict:
    result = context.step(my_step(event["arg"]))  # always context.step()
    return result
```

1. `@durable_execution` on handler only
2. `@durable_step` on every function with side effects
3. `context.step(step_fn(args))` — always; never call `step_fn(args)` directly
4. All boto3/Anthropic clients instantiated **inside** `@durable_step` functions — never at module or handler scope
5. Synchronous Python only — no `async/await`
6. `context.create_callback(name="human-review")` → `.callback_id` and `.result()`
7. `callback.result()` suspends execution at zero compute cost

## Environment Variables

| Lambda | Variable | Value |
|---|---|---|
| submission | `DYNAMODB_TABLE` | `careflow-prior-auth-requests` |
| submission | `ORCHESTRATOR_FUNCTION_NAME` | `careflow-{env}-orchestrator` |
| orchestrator | `DYNAMODB_TABLE` | `careflow-prior-auth-requests` |
| orchestrator | `REVIEWER_SNS_TOPIC_ARN` | from Terraform output |
| orchestrator | `DECISION_SNS_TOPIC_ARN` | from Terraform output |
| orchestrator | `API_GATEWAY_URL` | from Terraform output (optional, for review_url in SNS message) |
| reviewer_callback | `DYNAMODB_TABLE` | `careflow-prior-auth-requests` |

## Build & Deploy

```bash
# Build Lambda zip packages
./scripts/build.sh

# Deploy infrastructure
cd terraform
terraform init
terraform plan -var="anthropic_api_key=sk-ant-..." -out=tfplan
terraform apply tfplan

# Get API URL
terraform output api_gateway_url
```

## Testing

```bash
API_URL=$(cd terraform && terraform output -raw api_gateway_url)

# Submit a prior auth request
curl -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{"patient_id":"PAT-001","provider_id":"PROV-001","diagnosis_code":"J18.9","procedure_code":"99233"}'

# Check status (after ~20s)
aws dynamodb get-item --table-name careflow-prior-auth-requests \
  --key '{"request_id":{"S":"<request_id>"}}'

# For escalated requests — resolve with reviewer decision
curl -X POST "$API_URL/review/<callback_id>" \
  -H "Content-Type: application/json" \
  -d '{"decision":"approved","notes":"Medically necessary","reviewer_id":"DR-001"}'
```

## Decision Log

See `README.md` for the full decision log comparing Lambda Durable Functions vs Step Functions
and Claude API direct vs Amazon Bedrock.
