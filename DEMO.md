# CareFlow Demo Guide

**Total recording time: ~5 minutes**  
Follow each scene in order. `demo.sh` runs every command automatically — just press Enter to advance. Lines marked **SAY:** are your script.

---

## Before You Start Recording

```bash
chmod +x demo.sh   # one time only
```

Open the GitHub README in a browser tab. That's all — `demo.sh` handles everything else.

## Running the Demo

```bash
./demo.sh
```

Press **Enter** at each `▶ Press Enter to continue...` prompt to advance. Request IDs and callback IDs are captured automatically — nothing to copy-paste mid-recording.

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

## Scene 1.5 — Architecture Walkthrough (0:40 – 1:20)

**Action:** Open `architecture diagram.png` (repo root) in your browser.

> **SAY:**
> "This is the full system architecture. Three entry points into API Gateway — submit, review, and status."
>
> "The Submission Lambda is the entry point — it accepts both raw JSON and FHIR CoverageEligibilityRequest format, which is the standard real hospitals use."
>
> "The Orchestrator is the core — this is a Lambda Durable Function, a new AWS primitive that launched in December 2025."
>
> "Unlike standard Lambda which dies after 15 minutes, a Durable Function can suspend itself completely at zero compute cost — no CPU, no memory, no billing — and resume exactly where it stopped, even days later."
>
> "When Claude escalates a case, the orchestrator calls create_callback(), sends the callback ID to the reviewer via SNS, and then suspends. The Lambda is not running. AWS saves a checkpoint. The reviewer could respond in 5 minutes or 5 days — the cost is identical: zero."
>
> "When the reviewer submits their decision, the orchestrator resumes in 530 milliseconds from the exact line it suspended on. That's what you'll see in the demo."

**Point out on the diagram:** KMS CMK on the DynamoDB PHI table, Secrets Manager holding the API key, and Claude API sitting outside the AWS boundary.

---

## Scene 2 — Auto-Approval: Routine Case (1:20 – 2:40)

**Action:** Switch to the terminal running `demo.sh`. Press Enter to submit.

> **SAY:**
> "I'll submit a prior auth request for a patient with community-acquired pneumonia
> needing a follow-up hospital visit. This is a routine case — clear diagnosis,
> standard procedure. Watch how fast this resolves."

*`demo.sh` submits the request and prints the JSON response with the request ID.*

> **SAY:**
> "I get back a request ID immediately — the system is processing asynchronously.
> Now I'll poll the status. This is the part where you'd normally wait days."

*Press Enter. `demo.sh` polls automatically every 5 seconds until status leaves PENDING.*

> **SAY:**
> "There it is — APPROVED. Claude reviewed the clinical criteria, confirmed medical necessity,
> and made a decision. Total time: under 30 seconds. Industry average: 3 to 7 days.
> The cost for that AI inference call was less than one cent — $0.008865 to be exact,
> versus $11 to $14 in staff time for the same decision."

**Point to the response fields as you speak:**
> "You can see Claude's full reasoning, which policy criteria were met, confidence score,
> and the exact token cost — all stored in DynamoDB with a 90-day audit trail."

---

## Scene 3 — Escalation: Human Review (2:40 – 4:00)

> **SAY:**
> "Now let me show the escalation path — what happens when the AI isn't confident enough
> to decide on its own. Claude's confidence threshold is 90%. Below that, it escalates
> to a human reviewer automatically. No exceptions in code."

*Press Enter. `demo.sh` submits the escalation case and polls for status.*

> **SAY:**
> "Status is UNDER_REVIEW. The orchestrator evaluated the request, determined it needed
> human judgment, then suspended itself — at zero compute cost. It's not polling,
> not running, not burning money. It's just waiting. A reviewer gets an SNS notification
> with the case details and a callback URL. Let me resolve it now as the reviewer."

*Press Enter. `demo.sh` submits the reviewer decision using the captured callback ID.*

*Press Enter. `demo.sh` pulls the final status.*

> **SAY:**
> "APPROVED — resolved with the reviewer's notes, their ID, and a full timestamp attached.
> The orchestrator resumed in 530 milliseconds from exactly where it suspended.
> The reviewer's decision and reasoning are permanently in the audit trail."

---

## Scene 3.5 — Why Lambda Durable Functions (4:00 – 4:25)

**Action:** Stay on the terminal — the DynamoDB record from Scene 3 is already on screen.

> **SAY:**
> "Before Durable Functions existed, building human-in-the-loop on Lambda meant two bad options."
>
> "Option one: poll a database in a loop inside Lambda — hits the 15-minute wall immediately, and you're billed the entire wait."
>
> "Option two: Step Functions — works, but your workflow becomes a YAML state machine separate from your application code, you pay per state transition, and you've added another service boundary to reason about."
>
> "Durable Functions is a third model: write a single Python function, call callback.result(), and the Lambda checkpoints itself and disappears. Zero compute. Zero billing. When the reviewer responds, AWS resumes it from the exact line in under a second. You just saw that — 530 milliseconds. That primitive didn't exist before December 2025."

---

## Scene 4 — Wrap Up (4:25 – 5:05)

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

## Quick Reference

```bash
# One-time setup
chmod +x demo.sh

# Run the demo — press Enter at each prompt to advance
./demo.sh
```

`demo.sh` fetches the API URL from Terraform, submits all requests, captures IDs, polls status, and resolves the reviewer callback automatically. No copy-paste required at any point.

---

## Recording Tips

- Use a dark terminal theme — easier to read on video
- Increase font size to at least 16pt before recording
- `jq .` is already in every command — output will be formatted and colored
- If status still shows `PENDING` after 30s, wait 10 more seconds and re-run — Lambda cold starts can add a few seconds
- For the escalation scene, `F32.1 + 90837` reliably triggers escalation, but if it auto-approves, try `Z79.899 + 27447` (experimental implant for complex comorbidities)
