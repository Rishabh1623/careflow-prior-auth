# CareFlow Demo Guide

**Total recording time: ~4 minutes**  
Follow each scene in order. Commands are copy-paste ready. Lines marked **SAY:** are your script.

---

## Before You Start Recording

Run these once — do not record this part.

```bash
# Get your live API URL
cd terraform
export API_URL=$(terraform output -raw api_gateway_url)
echo $API_URL   # confirm it printed a URL
```

Open two terminal windows side by side — one to submit requests, one to poll status.  
Have the README open on GitHub in a browser tab.

---

## Scene 1 — The Problem (0:00 – 0:40)

**Action:** Show the GitHub README in the browser.

> **SAY:**
> "This is CareFlow — a prior authorization engine I built to solve a real healthcare problem.
> Today, routine prior authorizations take 3 to 7 business days. One in four patients abandons
> their treatment while waiting. And for what? Most of these requests are straightforward.
> CareFlow decides routine cases in under 30 seconds using AI, and routes genuinely complex
> ones to a human reviewer immediately — not after three days in a fax queue.
> Let me show you how it works."

---

## Scene 2 — Auto-Approval: Routine Case (0:40 – 2:00)

**Action:** Switch to Terminal 1.

> **SAY:**
> "I'll submit a prior auth request for a patient with community-acquired pneumonia
> needing a follow-up hospital visit. This is a routine case — clear diagnosis,
> standard procedure. Watch how fast this resolves."

**Run in Terminal 1:**
```bash
curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id": "PAT-001",
    "provider_id": "PROV-001",
    "diagnosis_code": "J18.9",
    "procedure_code": "99233",
    "clinical_notes": "Patient recovering from community-acquired pneumonia. Follow-up hospital observation required to monitor treatment response and ensure no complications."
  }' | jq .
```

> **SAY:**
> "I get back a request ID immediately — the system is processing asynchronously.
> Now I'll poll the status. This is the part where you'd normally wait days."

**Copy the `request_id` from the response. Run in Terminal 2:**
```bash
# Replace <request_id> with the value from above
curl -s "$API_URL/status/<request_id>" | jq .
```

*Wait 20–30 seconds, then run the status check again.*

> **SAY:**
> "There it is — APPROVED. Claude reviewed the clinical criteria, confirmed medical necessity,
> and made a decision. Total time: under 30 seconds. Industry average: 3 to 7 days.
> The cost for that AI inference call was less than one cent — $0.008865 to be exact,
> versus $11 to $14 in staff time for the same decision."

**Point to the response fields as you speak:**
> "You can see Claude's full reasoning, which policy criteria were met, confidence score,
> and the exact token cost — all stored in DynamoDB with a 90-day audit trail."

---

## Scene 3 — Escalation: Human Review (2:00 – 3:20)

> **SAY:**
> "Now let me show the escalation path — what happens when the AI isn't confident enough
> to decide on its own. Claude's confidence threshold is 90%. Below that, it escalates
> to a human reviewer automatically. No exceptions in code."

**Run in Terminal 1:**
```bash
curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id": "PAT-002",
    "provider_id": "PROV-002",
    "diagnosis_code": "F32.1",
    "procedure_code": "90837",
    "clinical_notes": "Patient presenting with moderate major depressive disorder. Requesting extended psychotherapy sessions. Previous treatments include medication management with partial response."
  }' | jq .
```

*Wait 20–30 seconds, then check status.*

```bash
curl -s "$API_URL/status/<request_id>" | jq .
```

> **SAY:**
> "Status is UNDER_REVIEW. The orchestrator evaluated the request, determined it needed
> human judgment, then suspended itself — at zero compute cost. It's not polling,
> not running, not burning money. It's just waiting. A reviewer gets an SNS notification
> with the case details and a callback URL. Let me resolve it now as the reviewer."

**Copy the `callback_id` from the status response. Run:**
```bash
curl -s -X POST "$API_URL/review/<callback_id>" \
  -H "Content-Type: application/json" \
  -d '{
    "decision": "approved",
    "notes": "Extended psychotherapy medically necessary given partial medication response. Meets clinical criteria for moderate MDD.",
    "reviewer_id": "DR-001"
  }' | jq .
```

*Check status one more time.*

```bash
curl -s "$API_URL/status/<request_id>" | jq .
```

> **SAY:**
> "APPROVED — resolved with the reviewer's notes, their ID, and a full timestamp attached.
> The orchestrator resumed in 530 milliseconds from exactly where it suspended.
> The reviewer's decision and reasoning are permanently in the audit trail."

---

## Scene 4 — Wrap Up (3:20 – 4:00)

**Action:** Switch back to the GitHub README in the browser. Point to the Results table.

> **SAY:**
> "To recap what you just saw: routine approvals in under 30 seconds, escalations routed
> immediately to a human, and zero compute cost while the system waits for a reviewer
> who might take hours or days to respond.
>
> The stack is Python on AWS Lambda with Anthropic Claude at temperature zero for
> determinism. Infrastructure is Terraform. 72 out of 72 tests passing.
>
> The architecture is production-shaped — KMS encryption on the PHI table, idempotent
> callbacks so duplicate reviewer submissions can't corrupt a patient's record,
> prompt injection screening on clinical notes, and FHIR input support so it speaks
> the language real hospitals already use.
>
> The gap to production is compliance paperwork — an Anthropic BAA, FIPS 140-3 in transit,
> SOC 2 — not a redesign. The engineering is already there."

---

## Quick Reference — All Commands

```bash
# Set URL (run once before recording)
export API_URL=$(cd terraform && terraform output -raw api_gateway_url)

# Submit a request
curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{"patient_id":"PAT-001","provider_id":"PROV-001","diagnosis_code":"J18.9","procedure_code":"99233"}' | jq .

# Check status
curl -s "$API_URL/status/<request_id>" | jq .

# Resolve human review
curl -s -X POST "$API_URL/review/<callback_id>" \
  -H "Content-Type: application/json" \
  -d '{"decision":"approved","notes":"Medically necessary","reviewer_id":"DR-001"}' | jq .
```

---

## Recording Tips

- Use a dark terminal theme — easier to read on video
- Increase font size to at least 16pt before recording
- `jq .` is already in every command — output will be formatted and colored
- If status still shows `PENDING` after 30s, wait 10 more seconds and re-run — Lambda cold starts can add a few seconds
- For the escalation scene, `F32.1 + 90837` reliably triggers escalation, but if it auto-approves, try `Z79.899 + 27447` (experimental implant for complex comorbidities)
