# CareFlow Prior Authorization Engine

> Routine prior authorizations decided in under 30 seconds. Complex cases routed to a human reviewer immediately — not after three days in a fax queue.

## Stack

Python 3.13 · AWS Lambda Durable Functions · Anthropic Claude (`claude-sonnet-4-6`, `temperature=0`) · DynamoDB · SNS · Secrets Manager · Terraform · API Gateway HTTP v2

## The Problem

Prior authorization takes 3–7 business days regardless of complexity. One in four patients abandons treatment while waiting. Doctor's offices spend 20–30 minutes of staff time per request.

## The Solution

| | Before | After |
|---|---|---|
| **Routine approvals** | 3–7 business days | Under 30 seconds |
| **Complex cases** | Same queue as routine | Reach a human reviewer immediately |
| **Doctor's office** | Repeated calls and fax follow-ups | Single API submission |
| **Cost per decision** | $11–$14 in staff time (CAQH, 2023) | $0.008865 in AI inference |

## Trust and Safety

- **Confidence threshold** — below 90%, AI escalates to human review automatically; no exceptions in code
- **Prompt injection screening** — clinical notes screened before AI evaluation; flagged content bypasses AI entirely and goes straight to a human
- **Schema validation** — Claude response validated against Pydantic schema before any action; parse failure → escalate
- **Idempotent callbacks** — atomic `attribute_not_exists` PutItem prevents duplicate authorization records
- **KMS encryption** — customer-managed key with rotation on the PHI table; callback-idempotency table unencrypted (no PHI)
- **Least-privilege IAM** — each Lambda has its own role scoped to exactly its resources

## Production Compliance Gap Analysis

### Already satisfied

| Requirement | How CareFlow addresses it |
|---|---|
| Human oversight mandate (CA SB 1120) | Confidence threshold routes uncertain AI decisions to human review — AI cannot decide autonomously |
| Audit trail (HIPAA Security Rule) | Every decision logged with reasoning, reviewer ID, timestamp, and cost |
| Minimum necessary access (HIPAA) | Per-Lambda IAM roles, no shared roles |
| Prompt injection defense | Clinical notes screened before AI evaluation |
| Duplicate resolution prevention | Atomic idempotency check prevents conflicting records |
| Encryption at rest | KMS CMK on prior-auth-requests DynamoDB table |

### Gaps before real PHI can flow

| Gap | Effort |
|---|---|
| Anthropic enterprise BAA | Low — paperwork, not engineering |
| FIPS 140-3 encryption in transit (2025 HIPAA amendments) | Medium |
| PHI de-identification before Claude API call | Medium |
| SOC 2 Type II audit | High — months |
| Full EHR webhook integration (FHIR `CoverageEligibilityRequest` input already supported) | High |

The architectural path from POC to production is compliance configuration and vendor agreements, not a fundamental redesign.

## Engineering Decisions

**Lambda Durable Functions over Step Functions** — suspended orchestrator costs zero while awaiting human review (hours to days); natural Python control flow with no separate state machine definition file.

**Claude API direct over Amazon Bedrock** — same-day model access, cleaner SDK, lower per-token cost; API key in Secrets Manager addresses the IAM compliance argument for Bedrock.

## Architecture

```
POST /submit  →  Submission Lambda  →  DynamoDB (PENDING)  →  Orchestrator (async)
                 accepts raw JSON + FHIR CoverageEligibilityRequest

Orchestrator  →  [injection screen]  →  Claude AI  →  save decision  →  SNS
              →  if escalate: SUSPEND at zero compute cost
              →  human POSTs /review/{callback_id}  →  RESUME  →  save  →  SNS

GET /status/{request_id}  →  Status Lambda  →  DynamoDB read-through
```

Full spec, DynamoDB schema, and SDK usage guide: [`CLAUDE.md`](CLAUDE.md)
