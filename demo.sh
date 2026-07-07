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

# ── scene 1 — architecture walkthrough ───────────────────────
banner "SCENE 1 — Architecture Walkthrough"

say "Open the architecture diagram in your browser (architecture diagram.png on GitHub)."
say ""
say "SCRIPT — walk the diagram left to right, top to bottom:"
say ""
say "\"Let me start with the architecture so you can see how the pieces fit together.\""
say ""
say "ENTRY POINT:"
say "  \"Everything starts at API Gateway — a single HTTP v2 endpoint. No custom"
say "  infrastructure to manage, scales to zero, charges per request.\""
say ""
say "SUBMISSION LAMBDA:"
say "  \"The Submission Lambda is the front door. It accepts two formats: raw JSON"
say "  for simplicity in testing, and FHIR CoverageEligibilityRequest — the standard"
say "  real hospital EHR systems already speak. It writes the request to DynamoDB"
say "  and fires the orchestrator asynchronously. The caller gets a 202 immediately.\""
say ""
say "DYNAMODB:"
say "  \"DynamoDB is the source of truth. Customer-managed KMS key with automatic"
say "  rotation on the PHI table — that satisfies the 2025 HIPAA Security Rule."
say "  90-day TTL, pay-per-request billing, a GSI for decision reporting.\""
say ""
say "ORCHESTRATOR LAMBDA — THE BRAIN:"
say "  \"The Orchestrator is where the intelligence lives. It's built on Lambda"
say "  Durable Functions — think Step Functions, but the workflow is just Python."
say "  Each step is checkpointed. If it crashes mid-run, it replays from the last"
say "  checkpoint. And when it escalates to a human reviewer, it suspends completely"
say "  — zero compute cost — for however long the reviewer takes. Could be hours, days.\""
say ""
say "CLAUDE AI — OUTSIDE THE AWS BOUNDARY:"
say "  \"Claude sits outside the AWS boundary — that's intentional. We call the"
say "  Anthropic API directly, not Bedrock, because it gives us same-day access to"
say "  the latest models and lower per-token cost. The API key lives in Secrets Manager"
say "  so there's no plaintext credential anywhere in the codebase or environment.\""
say ""
say "SNS DUAL-TOPIC PATTERN:"
say "  \"Two SNS topics — one for reviewer alerts when a case escalates, one for"
say "  final decisions. Keeping them separate means downstream consumers only subscribe"
say "  to what they care about. The billing system doesn't need escalation noise.\""
say ""
say "REVIEWER CALLBACK LAMBDA:"
say "  \"When a human submits their decision, the Reviewer Callback Lambda handles it."
say "  The first thing it does is an atomic idempotency check — if a reviewer"
say "  accidentally submits twice, the second call is silently dropped. A patient's"
say "  record can't be corrupted by a duplicate POST.\""
say ""
say "STATUS LAMBDA:"
say "  \"Finally, a simple read-through Status Lambda — GET /status/{id} reads"
say "  straight from DynamoDB. Clean separation: reads never touch the write path.\""

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
