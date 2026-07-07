#!/bin/bash
# CareFlow demo script — press Enter at each prompt to advance.
# All IDs are captured automatically. Nothing to copy-paste.

set -euo pipefail

# ── colours ─────────────────────────────────────────────────
BOLD='\033[1m'
BLUE='\033[1;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
RESET='\033[0m'

# ── helpers ──────────────────────────────────────────────────
pause() {
  echo ""
  read -rp "$(printf "${CYAN}▶  Press Enter to continue...${RESET}")"
  echo ""
}

banner() {
  echo ""
  printf "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  printf "${BOLD}${BLUE}  %s${RESET}\n" "$1"
  printf "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  echo ""
}

say() {
  # Talking point printed as a dim reminder — not a command
  printf "${DIM}  💬 %s${RESET}\n" "$1"
}

label() {
  printf "${BOLD}  ▸ %s${RESET}\n" "$1"
}

# Global — poll_status writes last response here so callers can parse it
LAST_STATUS_RESPONSE=""

poll_status() {
  local request_id="$1"
  local attempts=0
  local max=24   # 2 minutes max (24 × 5s)
  while [[ $attempts -lt $max ]]; do
    local response
    response=$(curl -s "$API_URL/status/$request_id")
    local status
    status=$(echo "$response" | jq -r '.status')
    echo "$response" | jq .
    LAST_STATUS_RESPONSE="$response"
    if [[ "$status" != "PENDING" ]]; then
      return 0
    fi
    printf "${YELLOW}  Still processing — retrying in 5s...${RESET}\n"
    sleep 5
    (( attempts++ ))
  done
  printf "${YELLOW}  Timed out after 2 minutes.${RESET}\n"
  return 1
}

# ── preflight ────────────────────────────────────────────────
banner "PREFLIGHT — not recorded"

for cmd in curl jq terraform; do
  if ! command -v "$cmd" &>/dev/null; then
    printf "${YELLOW}  Missing: %s — install it before recording.${RESET}\n" "$cmd"
    exit 1
  fi
done

label "Fetching API URL from Terraform..."
API_URL=$(terraform -chdir=terraform output -raw api_gateway_url)
printf "${GREEN}  API_URL = %s${RESET}\n" "$API_URL"
printf "${GREEN}  Ready. Start recording, then press Enter.${RESET}\n"

pause

# ── scene 1 — the problem ────────────────────────────────────
banner "SCENE 1 — The Problem"

say "ACTION: Show the GitHub README in the browser."
say ""
say "SCRIPT:"
say "  \"This is CareFlow — a prior authorization engine I built to solve a real"
say "  healthcare problem. Today, routine prior authorizations take 3 to 7 business"
say "  days. One in four patients abandons their treatment while waiting. And for what?"
say "  Most of these requests are straightforward. CareFlow decides routine cases in"
say "  under 30 seconds using AI, and routes genuinely complex ones to a human reviewer"
say "  immediately — not after three days in a fax queue. Let me show you how it works.\""

pause

# ── scene 1.5 — architecture walkthrough ─────────────────────
banner "SCENE 1.5 — Architecture Walkthrough"

say "ACTION: Open 'architecture diagram.png' in your browser (it's in the repo root)."
say ""
say "SCRIPT:"
say "  \"This is the full system architecture. Three entry points into API Gateway"
say "  — submit, review, and status.\""
say ""
say "  \"The Submission Lambda is the entry point — it accepts both raw JSON and FHIR"
say "  CoverageEligibilityRequest format, which is the standard real hospitals use.\""
say ""
say "  \"The Orchestrator is the core — this is a Lambda Durable Function, a new AWS"
say "  primitive that launched in December 2025.\""
say ""
say "  \"Unlike standard Lambda which dies after 15 minutes, a Durable Function can"
say "  suspend itself completely at zero compute cost — no CPU, no memory, no billing"
say "  — and resume exactly where it stopped, even days later.\""
say ""
say "  \"When Claude escalates a case, the orchestrator calls create_callback(), sends"
say "  the callback ID to the reviewer via SNS, and then suspends. The Lambda is not"
say "  running. AWS saves a checkpoint. The reviewer could respond in 5 minutes or"
say "  5 days — the cost is identical: zero.\""
say ""
say "  \"When the reviewer submits their decision, the orchestrator resumes in 530"
say "  milliseconds from the exact line it suspended on. That's what you'll see in the demo.\""
say ""
say "  Point out: KMS CMK on the DynamoDB PHI table, Secrets Manager holding the API"
say "  key, and Claude API sitting outside the AWS boundary."

pause

# ── scene 2 — auto-approval ──────────────────────────────────
banner "SCENE 2 — Auto-Approval: Routine Case"

say "SCRIPT:"
say "  \"Now let me show it live. I'll submit a routine case — community-acquired"
say "  pneumonia, follow-up hospital observation. Clear diagnosis, standard procedure.\""
say "  Watch how long this takes.\""

echo ""
label "Submitting: J18.9 (pneumonia) + 99233 (hospital observation)"
SUBMIT_1=$(curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id":     "PAT-001",
    "provider_id":    "PROV-001",
    "diagnosis_code": "J18.9",
    "procedure_code": "99233",
    "clinical_notes": "Patient recovering from community-acquired pneumonia. Follow-up hospital observation required to monitor treatment response and ensure no complications."
  }')
echo "$SUBMIT_1" | jq .
REQUEST_ID_1=$(echo "$SUBMIT_1" | jq -r '.request_id')
printf "${GREEN}  ✓ request_id captured${RESET}\n"

say "\"I get back a request ID immediately — processing is async.\""
say "\"Normally you'd wait 3 to 7 days. Watch this.\""

pause

label "Polling status..."
poll_status "$REQUEST_ID_1"

say "\"APPROVED. Under 30 seconds. Cost: \$0.008865 in AI inference.\""
say "\"Point out: decision, claude_reasoning, policy_criteria_met, estimated_cost_usd.\""
say "\"Industry average for the same decision: \$11 to \$14 in staff time.\""

pause

# ── scene 3 — escalation + human review ─────────────────────
banner "SCENE 3 — Escalation + Human Review"

say "SCRIPT:"
say "  \"Not every case is straightforward. Claude's confidence threshold is 90%."
say "  Below that it doesn't guess — it escalates to a human reviewer immediately."
say "  Let me show that path.\""

echo ""
label "Submitting: F32.1 (major depressive disorder) + 90837 (psychotherapy)"
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
printf "${GREEN}  ✓ request_id captured${RESET}\n"

say "\"Same async submission. Now watch what comes back.\""

pause

label "Polling status — expecting UNDER_REVIEW..."
poll_status "$REQUEST_ID_2"

FINAL_STATUS=$(echo "$LAST_STATUS_RESPONSE" | jq -r '.status')
if [[ "$FINAL_STATUS" != "UNDER_REVIEW" ]]; then
  printf "${YELLOW}  Case resolved as %s — not UNDER_REVIEW.${RESET}\n" "$FINAL_STATUS"
  printf "${YELLOW}  Re-run with diagnosis_code Z79.899 + procedure_code 27447 for a reliable escalation.${RESET}\n"
  exit 0
fi

CALLBACK_ID=$(echo "$LAST_STATUS_RESPONSE" | jq -r '.callback_id')
printf "${GREEN}  ✓ callback_id captured${RESET}\n"

say "\"UNDER_REVIEW. The orchestrator evaluated the case, decided it needed human judgment,"
say " notified the reviewer via SNS, and then suspended itself — at zero compute cost."
say " It is not polling. It is not running. It costs nothing while it waits.\""
say "\"I'll now act as the reviewer and POST my decision.\""

pause

label "Submitting reviewer decision as DR-001..."
curl -s -X POST "$API_URL/review/$CALLBACK_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "decision":    "approved",
    "notes":       "Extended psychotherapy medically necessary given partial medication response. Meets clinical criteria for moderate MDD.",
    "reviewer_id": "DR-001"
  }' | jq .

say "\"The orchestrator just resumed — in 530 milliseconds. Let me pull the final record.\""

pause

label "Final status..."
curl -s "$API_URL/status/$REQUEST_ID_2" | jq .

say "\"APPROVED. Reviewer's notes, their ID, and the timestamp are all in the audit trail."
say " Permanent record — satisfies HIPAA audit requirements out of the box.\""

pause

# ── scene 3.5 — why lambda durable functions ─────────────────
banner "SCENE 3.5 — Why Lambda Durable Functions"

say "ACTION: Stay on terminal. The DynamoDB record you just pulled is already on screen."
say ""
say "SCRIPT:"
say "  \"Before Durable Functions existed, building human-in-the-loop on Lambda meant"
say "  two bad options.\""
say ""
say "  \"Option one: poll a database in a loop inside Lambda — hits the 15-minute wall"
say "  immediately, and you're billed the entire wait.\""
say ""
say "  \"Option two: Step Functions — works, but your workflow becomes a YAML state"
say "  machine separate from your application code, you pay per state transition, and"
say "  you've added another service boundary to reason about.\""
say ""
say "  \"Durable Functions is a third model: write a single Python function, call"
say "  callback.result(), and the Lambda checkpoints itself and disappears. Zero compute."
say "  Zero billing. When the reviewer responds, AWS resumes it from the exact line in"
say "  under a second. You just saw that — 530 milliseconds. That primitive didn't"
say "  exist before December 2025.\""

pause

# ── scene 4 — wrap up ────────────────────────────────────────
banner "SCENE 4 — Wrap Up"

say "Switch to the GitHub README. Point to the Results table."
say ""
say "SCRIPT:"
say "  \"What you just saw: routine approvals in under 30 seconds, escalations routed"
say "  instantly to a human, and zero compute spend while the system waits — whether"
say "  that's 10 minutes or 2 days.\""
say ""
say "  \"72 out of 72 tests passing. KMS encryption on the PHI table. Idempotent callbacks."
say "  FHIR input. Prompt injection screening on clinical notes.\""
say ""
say "  \"The gap to production is compliance paperwork — an Anthropic BAA, FIPS 140-3"
say "  in transit, SOC 2. The architecture is already there.\""

echo ""
printf "${GREEN}${BOLD}  Demo complete.${RESET}\n"
echo ""
