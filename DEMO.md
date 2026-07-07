# CareFlow — Presenter Script

**Total time: ~4 minutes**  
Copy-paste each command block as you reach it in the demo.

---

## Setup — run before recording

```bash
API_URL=$(terraform -chdir=terraform output -raw api_gateway_url)
echo "API_URL = $API_URL"
```

---

## Scene 1 — The Problem (0:00 – 0:40)

**Action:** Show the GitHub README in the browser.

> "This is CareFlow — a prior authorization engine I built to solve a real healthcare problem.
>
> Today, routine prior authorizations take 3 to 7 business days. One in four patients abandons their treatment while waiting. Doctor's offices spend 20 to 30 minutes of staff time per request chasing fax queues.
>
> And for what? Most of these requests are straightforward. CareFlow decides routine cases in under 30 seconds using AI, and routes genuinely complex ones to a human reviewer immediately — not after three days in a fax queue.
>
> Let me show you how it works."

---

## Scene 1.5 — Architecture Walkthrough (0:40 – 1:20)

**Action:** Open `architecture diagram.png` in the browser (repo root).

> "This is the full system architecture. Three entry points into API Gateway — submit, review, and status."

> "The **Submission Lambda** is the entry point. It accepts both raw JSON and FHIR `CoverageEligibilityRequest` format — that's the standard real hospitals already use, so there's no translation layer needed on their end."

> "The **Orchestrator** is the core of the system. This is a Lambda Durable Function — a new AWS primitive that launched in December 2025."

> "Unlike a standard Lambda which dies after 15 minutes, a Durable Function can suspend itself completely — no CPU, no memory, no billing — and resume exactly where it stopped, even days later. I'll show you that live in a moment."

> "When Claude escalates a case, the orchestrator calls `create_callback()`, sends the callback ID to the reviewer via SNS, and then suspends. The Lambda is not running. AWS saves a checkpoint. The reviewer could respond in 5 minutes or 5 days — the cost is identical: zero."

> "When the reviewer submits their decision, the orchestrator resumes in 530 milliseconds from the exact line it suspended on."

> "The **Reviewer Callback Lambda** handles `POST /review`. The first thing it does is an atomic idempotency check using `attribute_not_exists` on DynamoDB. If a reviewer accidentally submits twice, the second call is silently dropped. A patient's record cannot be corrupted by a duplicate POST."

> "And the **Status Lambda** is a simple read-through — `GET /status/{id}` reads straight from DynamoDB. Reads never touch the write path."

**Point out on the diagram:** KMS customer-managed key on the DynamoDB PHI table, Secrets Manager holding the Anthropic API key, and Claude API sitting outside the AWS boundary.

---

## Scene 2 — Async Submission (1:20 – 1:45)

**Action:** Switch to the terminal.

> "I'll submit a prior auth request for a patient with CT-confirmed acute appendicitis needing an immediate appendectomy. The imaging shows it, the labs confirm it, the surgeon is recommending it."

```bash
SUBMIT_1=$(curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id":     "PAT-001",
    "provider_id":    "PROV-001",
    "diagnosis_code": "K35.80",
    "procedure_code": "44950",
    "clinical_notes": "Patient presenting with acute appendicitis confirmed by CT scan showing periappendiceal fat stranding. WBC 14,000. Pain score 8/10 right lower quadrant. Surgeon recommends immediate appendectomy to prevent perforation."
  }')
echo "$SUBMIT_1" | jq .
REQUEST_ID_1=$(echo "$SUBMIT_1" | jq -r '.request_id')
echo "REQUEST_ID_1 = $REQUEST_ID_1"
```

> "I get back a request ID immediately — the system is processing asynchronously in the background. This is the part where you'd normally wait 3 to 7 days. Let me show you what actually happens."

---

## Scene 3 — Escalation + Human Review (1:45 – 3:05)

> "Not every case is straightforward. Claude's confidence threshold is 90%. Below that it doesn't guess — it escalates to a human reviewer immediately. Let me show that path."

**Submit the escalation case:**

```bash
SUBMIT_2=$(curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id":     "PAT-002",
    "provider_id":    "PROV-002",
    "diagnosis_code": "F32.1",
    "procedure_code": "90837",
    "clinical_notes": "Patient presenting with moderate major depressive disorder. Requesting extended psychotherapy sessions. Previous treatments include medication management with partial response."
  }')
echo "$SUBMIT_2" | jq .
REQUEST_ID_2=$(echo "$SUBMIT_2" | jq -r '.request_id')
echo "REQUEST_ID_2 = $REQUEST_ID_2"
```

> "Same immediate response. Now I'll check the status after about 20 seconds."

**Check status (run after ~20s):**

```bash
curl -s "$API_URL/status/$REQUEST_ID_2" | jq .
```

> "UNDER_REVIEW. The orchestrator evaluated this case, decided it needed human judgment, notified the reviewer via SNS, and then suspended itself at zero compute cost. It is not polling. It is not running. It costs nothing while it waits."

**Capture the callback ID:**

```bash
CALLBACK_ID=$(curl -s "$API_URL/status/$REQUEST_ID_2" | jq -r '.callback_id')
echo "CALLBACK_ID = $CALLBACK_ID"
```

> "I'll now act as the reviewer and POST my decision."

**Submit the reviewer decision:**

```bash
curl -s -X POST "$API_URL/review/$CALLBACK_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "decision":    "approved",
    "notes":       "Extended psychotherapy medically necessary given partial medication response. Meets clinical criteria for moderate MDD.",
    "reviewer_id": "DR-001"
  }' | jq .
```

> "The orchestrator just resumed — in 530 milliseconds. Let me pull the final record."

**Final status:**

```bash
curl -s "$API_URL/status/$REQUEST_ID_2" | jq .
```

> "APPROVED. The reviewer's notes, their ID, and the timestamp are all in the audit trail. Permanent record — satisfies HIPAA audit requirements out of the box."

---

## Scene 3.5 — Why Lambda Durable Functions (3:05 – 3:30)

**Action:** Stay on the terminal — the DynamoDB record from Scene 3 is already on screen.

> "Before Durable Functions existed, building human-in-the-loop on Lambda meant two bad options."

> "Option one: poll a database in a loop inside the Lambda itself. That hits the 15-minute execution wall immediately — and you're billed the entire wait, whether the reviewer responds or not."

> "Option two: Step Functions. That works, but your workflow becomes a YAML state machine that lives outside your application code. You pay per state transition, you've added another service boundary to reason about, and your business logic is now split across two places."

> "Durable Functions is a third model: write a single Python function, call `callback.result()`, and the Lambda checkpoints itself and disappears. Zero compute. Zero billing. When the reviewer responds, AWS resumes it from the exact line in under a second. You just saw that — 530 milliseconds. That primitive didn't exist before December 2025."

---

## Scene 4 — Wrap Up (3:30 – 4:10)

**Action:** Switch back to the GitHub README in the browser. Point to the Results table.

> "To recap what you just saw: routine approvals in under 30 seconds, escalations routed immediately to a human, and zero compute cost while the system waits — whether the reviewer takes 10 minutes or 2 days."

> "72 out of 72 tests passing. KMS encryption on the PHI table. Idempotent callbacks. FHIR input. Prompt injection screening on clinical notes."

> "The gap to production is compliance paperwork — an Anthropic BAA, FIPS 140-3 in transit, SOC 2. The architecture is already there."
