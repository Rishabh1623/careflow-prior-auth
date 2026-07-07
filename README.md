# CareFlow Prior Authorization Engine

Prior authorization delays routine approvals 3–7 business days. One in four patients abandons treatment while waiting. Doctor's offices spend 20–30 minutes of staff time per request chasing fax queues. CareFlow eliminates the wait for routine cases and routes genuinely complex ones to a human reviewer immediately — not after three days in a queue.

## Results

| Metric | Before | After |
|---|---|---|
| Routine approvals | 3–7 business days | Under 30 seconds |
| Cost per decision | $11–$14 staff time (CAQH, 2023) | $0.008865 AI inference |
| Complex cases | Same queue as routine | Human reviewer notified immediately |
| Test suite | — | 72/72 passing |

**Checkpoint proof:** durable orchestrator resumes in 530ms after suspension vs 13,186ms cold start — state picks up exactly where it left off, even after days of waiting.

## Solution

Claude (`claude-sonnet-4-6`, `temperature=0`) evaluates each request and returns one of three verdicts: **approve**, **deny**, or **escalate**. Approve and deny resolve in seconds. Escalate suspends the orchestrator at zero compute cost and notifies a human reviewer; the workflow resumes the moment they respond.

Inputs accepted: raw JSON or FHIR `CoverageEligibilityRequest` — speaks the language real hospitals already use.

![CareFlow Architecture](architecture%20diagram.png)

*Submission and decision (blue) paths; human-review escalation (orange) flows. Claude API sits outside the AWS boundary.*

## How It Works

```
POST /submit  →  Submission Lambda  →  DynamoDB (PENDING)  →  Orchestrator (async)

Orchestrator:
  1. Screen clinical notes for prompt injection
  2. Evaluate with Claude → approve / deny / escalate
  if approve or deny:  save decision → SNS → DONE
  if escalate:  SUSPEND (zero compute) → notify reviewer
                human POSTs /review/{callback_id} → RESUME → save → SNS → DONE

GET /status/{request_id}  →  Status Lambda  →  DynamoDB read-through
```

Four Lambdas handle distinct responsibilities: **Submission** (API entry + FHIR parsing), **Orchestrator** (AI evaluation + durable workflow), **Reviewer Callback** (human resolution), **Status** (read-through). DynamoDB holds request state with 90-day TTL; dual SNS topics fan out reviewer alerts and final decisions separately.

## Demo

See [`DEMO.md`](DEMO.md) for the full presenter script and [`demo-commands.sh`](demo-commands.sh) for the copy-paste commands.

## Engineering Decisions

| Decision | Business reason |
|---|---|
| Lambda Durable Functions over Step Functions | Orchestrator suspends at **zero compute cost** while awaiting a reviewer — could be hours or days |
| Claude API direct over Amazon Bedrock | Same-day model access, lower per-token cost; API key in Secrets Manager satisfies the IAM compliance argument for Bedrock |
| Confidence threshold → escalate at < 90% | Claude doesn't make a final call when uncertain — human decides instead; no exceptions in code |
| KMS customer-managed key + rotation | PHI protected at rest; satisfies 2025 HIPAA Security Rule amendments |
| Idempotent callbacks (atomic `attribute_not_exists`) | Duplicate reviewer submissions can't corrupt a patient's record |
| Prompt injection screen on clinical notes | Flagged content skips AI entirely and goes straight to human review |

## Compliance Gap Analysis

### Already satisfied

| Requirement | How CareFlow addresses it |
|---|---|
| Human oversight mandate (CA SB 1120) | Confidence threshold routes uncertain decisions to human — AI cannot decide alone |
| Audit trail (HIPAA Security Rule) | Every decision logged with reasoning, reviewer ID, timestamp, and cost |
| Minimum necessary access (HIPAA) | Per-Lambda IAM roles scoped to exactly their resources |
| Encryption at rest | KMS CMK with automatic rotation on the PHI table |
| FHIR interoperability | `CoverageEligibilityRequest` input supported natively |
| Duplicate resolution prevention | Atomic idempotency check prevents conflicting records |

### Gaps before real PHI can flow

| Gap | Effort |
|---|---|
| Anthropic enterprise BAA | Low — paperwork, not engineering |
| FIPS 140-3 encryption in transit (2025 HIPAA) | Medium |
| PHI de-identification before Claude API call | Medium |
| SOC 2 Type II audit | High — months |
| Full EHR webhook integration | High |

The path from POC to production is compliance configuration and vendor agreements — not a redesign.

---

**Stack:** Python 3.13 · AWS Lambda Durable Functions · Anthropic Claude (`claude-sonnet-4-6`, `temperature=0`) · DynamoDB · SNS · KMS · Terraform · API Gateway HTTP v2

Full spec, DynamoDB schema, and SDK patterns: [`CLAUDE.md`](CLAUDE.md)
