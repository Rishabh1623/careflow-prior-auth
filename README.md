# CareFlow Prior Authorization Engine

> Routine prior authorizations decided in under 30 seconds. Complex cases routed to a human reviewer immediately — not after three days in a fax queue.

## The Problem

Before a doctor can perform many procedures or prescribe certain medications, they need approval from the patient's insurance company. Today that process takes 3–7 business days — regardless of complexity — for a decision that most cases will receive anyway.

One in four patients abandons treatment while waiting. Doctor's offices spend 20–30 minutes of staff time per request on calls and fax follow-ups, multiplied across thousands of requests per month.

The current system was designed for paper faxes. It hasn't fundamentally changed.

## The Solution

CareFlow evaluates straightforward requests against clinical criteria in real time and approves them in under 30 seconds. Ambiguous or high-risk cases route to a human reviewer immediately, with context pre-prepared — not after sitting in the same queue as routine requests.

| | Before | After |
|---|---|---|
| **Routine approvals** | 3–7 business days | Under 30 seconds |
| **Complex cases** | Same queue as routine | Reach a human reviewer immediately |
| **Doctor's office** | Repeated calls and fax follow-ups | Single API submission |
| **Patient experience** | Days of uncertainty | Near-instant answer for routine cases |
| **Audit trail** | Paper records | Every decision logged with full reasoning |

## Cost

A full evaluation — fetch, screen, evaluate, record — costs **$0.008865** in AI inference. The industry estimate for a single prior authorization on the provider side is $11–$14 in staff time (CAQH, 2023).

## Why Trust Matters

**Confidence threshold.** Every evaluation includes a confidence score; below 90%, the request escalates to a human regardless of what the AI recommended.

**Prompt injection screening.** Clinical notes are screened for manipulation before the main evaluation. Anything flagged bypasses the AI entirely and goes straight to human review.

**Idempotent callbacks.** Reviewer decisions are claimed atomically. A duplicate submission returns a 409 — it cannot overwrite the existing record.

## Security

- API key in Secrets Manager, fetched at runtime — never in environment variables
- Prompt injection screen runs before every evaluation that includes clinical notes
- Reviewer callback uses `attribute_not_exists` conditional `PutItem` to atomically claim each ID
- Confidence threshold enforced in code — below 90% → escalate, no exceptions
- Claude response validated against Pydantic schema before any action; parse failure → escalate
- IAM least privilege — each Lambda has its own role scoped to exactly its resources
- DynamoDB requests table encrypted with a customer-managed KMS key (rotation enabled); callback-idempotency table uses AWS-managed encryption (no PHI)

## Production Compliance Gap Analysis

CareFlow's architecture satisfies the core regulatory requirements for AI in prior authorization — human oversight for uncertain decisions, full audit trail per decision, and least-privilege data access. The following table documents what's in place and what would be required before real PHI could flow through this system.

### What CareFlow already satisfies

| Requirement | How CareFlow addresses it |
|---|---|
| Human oversight mandate (CA SB 1120) | Confidence threshold routes uncertain AI decisions to human review — AI cannot make final coverage decisions autonomously |
| Audit trail (HIPAA Security Rule) | Every decision logged in DynamoDB with decision, reasoning, reviewer ID, timestamp, and cost |
| Minimum necessary access (HIPAA) | Each Lambda has its own IAM role scoped to exactly the resources it needs — no shared roles |
| Prompt injection defense | Clinical notes screened before AI evaluation — flagged content bypasses AI entirely |
| Duplicate resolution prevention | Atomic idempotency check prevents conflicting authorization records |
| Encryption at rest | KMS customer-managed key on the prior-auth-requests DynamoDB table |

### What's needed before real PHI can flow through this system

| Gap | What's required | Effort |
|---|---|---|
| Business Associate Agreement | Anthropic enterprise BAA must be signed before clinical notes containing real PHI touch the Claude API | Low — paperwork, not engineering |
| FIPS 140-3 encryption in transit | Standard TLS must be replaced with FIPS 140-3 validated cryptographic modules per 2025 HIPAA Security Rule amendments | Medium |
| PHI de-identification option | Clinical notes should be de-identified before Claude API call, or BAA must be in place | Medium |
| SOC 2 Type II audit | Third-party security audit required by most hospital procurement teams | High — months |
| EHR integration | Real hospitals submit via HL7 FHIR from Epic/Cerner — FHIR input path is already supported, full EHR webhook integration is not | High |

CareFlow already ships with `CoverageEligibilityRequest` input support in the submission Lambda. The architectural path from POC to production is compliance configuration and vendor agreements, not a fundamental redesign.

## Engineering Decisions

### Lambda Durable Functions vs Step Functions

| Factor | Lambda Durable Functions | Step Functions |
|---|---|---|
| Code model | Pure Python, natural control flow | Amazon States Language (ASL) JSON/YAML |
| Human-in-the-loop | Built-in `create_callback()` + `callback.result()` | `waitForTaskToken` pattern |
| Compute cost during wait | **Zero** — Lambda exits while suspended | Standard Workflows bill per state transition only (no duration charge, but execution stays open against the 1M open-execution account quota) |
| Developer experience | All orchestration logic in one Python file | Separate state machine definition file |
| Debugging | Single Lambda log group per execution | Visual console but separate execution model |
| Execution duration | Configurable; **30 days** in this project (`execution_timeout=2592000`) | Up to 1 year (Standard) |

**Chosen: Lambda Durable Functions.** The suspended orchestrator costs nothing while waiting for a human reviewer — which could be hours or days. Step Functions Standard Workflows don't charge per duration either, but each step transition is billed and the execution stays open consuming the per-account open-execution quota.

### Claude API vs Amazon Bedrock

| Factor | Claude API Direct | Amazon Bedrock |
|---|---|---|
| Model availability | Same-day access to `claude-sonnet-4-6` | Subject to Bedrock's release schedule |
| API surface | Full Anthropic API (system prompt, temperature, content blocks) | Bedrock converse API — different request/response shape |
| Authentication | API key in Secrets Manager | AWS IAM / SigV4 signing |
| SDK | `anthropic` Python package — clean, typed | `boto3` `bedrock-runtime` — verbose |
| Pricing | Direct Anthropic pricing ($3/$15 per MTok in/out) | AWS markup added on top |

**Chosen: Claude API direct.** Same-day model access, cleaner SDK, lower per-token cost. The API key in Secrets Manager addresses the IAM compliance argument for Bedrock.

## API Reference

### `POST /submit`

Accepts two body formats — both return `202 { request_id, status }`.

**Format A — raw JSON**
```json
{ "patient_id": "PAT-001", "provider_id": "PROV-001", "diagnosis_code": "J18.9", "procedure_code": "99233", "clinical_notes": "Optional" }
```

**Format B — FHIR `CoverageEligibilityRequest`**
```json
{
  "resourceType": "CoverageEligibilityRequest",
  "patient":  { "reference": "Patient/PAT-001" },
  "provider": { "reference": "Practitioner/PROV-001" },
  "item": [{
    "diagnosis":        [{ "diagnosisCodeableConcept": { "coding": [{ "code": "J18.9" }] } }],
    "productOrService": { "coding": [{ "code": "99233" }] }
  }],
  "extension": [{ "url": "http://careflow.io/fhir/clinical-notes", "valueString": "Optional" }]
}
```

Detection is automatic: presence of `"resourceType": "CoverageEligibilityRequest"` triggers FHIR parsing. The `Patient/` / `Practitioner/` / `Organization/` prefix is stripped from references automatically. Both formats follow the identical internal workflow after parsing.

Errors: `400` on validation failure or malformed FHIR.

### `GET /status/{request_id}`

```json
{ "request_id": "...", "status": "APPROVED", "ai_decision": "approve", "ai_confidence": "0.95", "submitted_at": "...", "resolved_at": "..." }
```

Status values: `PENDING` / `APPROVED` / `DENIED` / `UNDER_REVIEW`. Errors: `404` not found, `400` missing parameter.

### `POST /review/{callback_id}`

```json
{ "decision": "approved", "notes": "Medically necessary.", "reviewer_id": "DR-JONES-007" }
```

Returns `200` on success. Errors: `409` already resolved, `404` not found, `400` invalid decision.

## Quick Start

```bash
./scripts/build.sh
cd terraform
terraform init -backend-config=backends/dev.hcl
terraform plan -var="anthropic_api_key=sk-ant-..." -out=tfplan
terraform apply tfplan
export API_URL=$(terraform output -raw api_gateway_url)
```

```bash
# Submit
curl -X POST "$API_URL/submit" -H "Content-Type: application/json" \
  -d '{"patient_id":"PAT-001","provider_id":"PROV-001","diagnosis_code":"J18.9","procedure_code":"99233"}'

# Check status
curl "$API_URL/status/<request_id>"

# Resolve escalated request
curl -X POST "$API_URL/review/<callback_id>" -H "Content-Type: application/json" \
  -d '{"decision":"approved","notes":"Medically necessary","reviewer_id":"DR-001"}'
```

## Project Structure

```
careflow-prior-auth/
├── CLAUDE.md                          # Full project spec and SDK usage guide
├── docs/
│   └── careflow-architecture.drawio   # Architecture diagram (all components and connections)
├── scripts/
│   └── build.sh                       # Packages Lambdas into deployment zips
├── src/
│   ├── orchestrator/
│   │   ├── handler.py                 # @durable_execution — prompt injection screen, Claude eval, callback
│   │   └── requirements.txt
│   ├── submission/
│   │   ├── handler.py                 # Standard Lambda — API Gateway entry point
│   │   └── requirements.txt
│   ├── reviewer_callback/
│   │   ├── handler.py                 # Standard Lambda — atomic idempotency claim, resolves durable callback
│   │   └── requirements.txt
│   └── status/
│       ├── handler.py                 # Standard Lambda — GET /status/{request_id}
│       └── requirements.txt
└── terraform/
    ├── main.tf                        # Provider, backend, locals
    ├── variables.tf                   # aws_region, environment, anthropic_api_key
    ├── outputs.tf                     # API URL, Lambda ARNs, SNS ARNs
    ├── dynamodb.tf                    # Requests table (PAY_PER_REQUEST, TTL) + idempotency table
    ├── sns.tf                         # Reviewer + decisions topics
    ├── lambda.tf                      # 4 Lambdas — orchestrator has durable_config (30-day suspension)
    ├── iam.tf                         # Least-privilege roles per Lambda + Secrets Manager secret
    └── api_gateway.tf                 # HTTP API v2, 3 routes, Lambda integrations
```
