# CareFlow — Presenter Script

**Total time: ~4 minutes**  
Commands are in `demo-commands.sh` — copy-paste each block as you reach it.

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

**Action:** Switch to the terminal. Run the **SCENE 2** block from `demo-commands.sh`.

> "I'll submit a prior auth request for a patient with CT-confirmed acute appendicitis needing an immediate appendectomy. The imaging shows it, the labs confirm it, the surgeon is recommending it."

*Paste and run the SCENE 2 block. The JSON response with the request ID prints immediately.*

> "I get back a request ID immediately — the system is processing asynchronously in the background. This is the part where you'd normally wait 3 to 7 days. Let me show you what actually happens."

---

## Scene 3 — Escalation + Human Review (1:45 – 3:05)

> "Not every case is straightforward. Claude's confidence threshold is 90%. Below that it doesn't guess — it escalates to a human reviewer immediately. Let me show that path."

**Action:** Run the **SCENE 3 — Submit** block from `demo-commands.sh`.

*Paste and run the SCENE 3 submit block. The 202 response with the second request ID prints.*

> "Same immediate response. Now I'll check the status after about 20 seconds."

**Action:** Wait ~20 seconds, then run the **SCENE 3 — Check status** block.

> "UNDER_REVIEW. The orchestrator evaluated this case, decided it needed human judgment, notified the reviewer via SNS, and then suspended itself at zero compute cost. It is not polling. It is not running. It costs nothing while it waits."

**Action:** Run the **SCENE 3 — Capture callback ID** block.

> "I'll now act as the reviewer and POST my decision."

**Action:** Run the **SCENE 3 — Submit reviewer decision** block.

> "The orchestrator just resumed — in 530 milliseconds. Let me pull the final record."

**Action:** Run the **SCENE 3 — Final status** block.

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
