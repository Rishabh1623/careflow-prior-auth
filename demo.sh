#!/bin/bash
# CareFlow demo script — run this while recording.
# Press Enter at each pause to advance to the next step.
# IDs are captured automatically — nothing to copy-paste.

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

label() {
  printf "${DIM}▸ %s${RESET}\n" "$1"
}

poll_status() {
  local request_id="$1"
  local attempts=0
  local max=24   # 2 minutes max
  while [[ $attempts -lt $max ]]; do
    local response
    response=$(curl -s "$API_URL/status/$request_id")
    local status
    status=$(echo "$response" | jq -r '.status')
    echo "$response" | jq .
    if [[ "$status" != "PENDING" ]]; then
      echo "$response"
      return 0
    fi
    printf "${YELLOW}  Still processing — retrying in 5s...${RESET}\n"
    sleep 5
    (( attempts++ ))
  done
  printf "${YELLOW}  Timed out waiting for status change.${RESET}\n"
  return 1
}

# ── preflight ────────────────────────────────────────────────
banner "PREFLIGHT — checking dependencies"

for cmd in curl jq terraform; do
  if ! command -v "$cmd" &>/dev/null; then
    printf "${YELLOW}  Missing: %s — please install it before running this script.${RESET}\n" "$cmd"
    exit 1
  fi
done

label "Getting API URL from Terraform..."
API_URL=$(terraform -chdir=terraform output -raw api_gateway_url)
printf "${GREEN}  API_URL = %s${RESET}\n" "$API_URL"

# ── scene 1 ──────────────────────────────────────────────────
banner "SCENE 1 — Introduction"

printf "${DIM}  Open the GitHub README in your browser now.\n"
printf "  Talk through the problem: 3–7 day delays, 1-in-4 patients abandoning treatment,\n"
printf "  \$11–\$14 staff cost per request.${RESET}\n"

pause

# ── scene 2 ──────────────────────────────────────────────────
banner "SCENE 2 — Auto-Approval: Routine Case"

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

pause

label "Polling status — watch this resolve in under 30 seconds..."
FINAL_1=$(poll_status "$REQUEST_ID_1")

pause

printf "${DIM}  Point out: decision, reasoning, policy_criteria_met, estimated_cost_usd${RESET}\n"

pause

# ── scene 3 ──────────────────────────────────────────────────
banner "SCENE 3 — Escalation + Human Review"

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

pause

label "Polling status — expect UNDER_REVIEW..."
STATUS_2=$(poll_status "$REQUEST_ID_2")

FINAL_STATUS=$(echo "$STATUS_2" | jq -r '.status')
if [[ "$FINAL_STATUS" != "UNDER_REVIEW" ]]; then
  printf "${YELLOW}  Case resolved as %s instead of UNDER_REVIEW.\n" "$FINAL_STATUS"
  printf "  Try re-running with Z79.899 + 27447 for a reliable escalation.${RESET}\n"
  exit 0
fi

CALLBACK_ID=$(echo "$STATUS_2" | jq -r '.callback_id')
printf "${GREEN}  ✓ callback_id captured — orchestrator is suspended at zero cost${RESET}\n"

pause

label "Resolving as human reviewer DR-001..."
curl -s -X POST "$API_URL/review/$CALLBACK_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "decision":    "approved",
    "notes":       "Extended psychotherapy medically necessary given partial medication response. Meets clinical criteria for moderate MDD.",
    "reviewer_id": "DR-001"
  }' | jq .

pause

label "Final status — orchestrator resumed and closed the case..."
curl -s "$API_URL/status/$REQUEST_ID_2" | jq .

pause

# ── scene 4 ──────────────────────────────────────────────────
banner "SCENE 4 — Wrap Up"

printf "${DIM}  Switch to the GitHub README.\n"
printf "  Close with the numbers: 30s, \$0.008865/decision, 72/72 tests, 530ms resume.\n"
printf "  End with: the gap to production is compliance paperwork, not a redesign.${RESET}\n"

echo ""
printf "${GREEN}${BOLD}  Demo complete.${RESET}\n"
echo ""
