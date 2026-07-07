#!/bin/bash
# CareFlow demo — copy-paste each block manually as you present.
# Run the SETUP block first, then each scene in order.

# ── SETUP ────────────────────────────────────────────────────
API_URL=$(terraform -chdir=terraform output -raw api_gateway_url)
echo "API_URL = $API_URL"


# ── SCENE 2 — Submit appendicitis case ───────────────────────
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


# ── SCENE 3 — Submit MDD escalation case ─────────────────────
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


# ── SCENE 3 — Check escalation status (run after ~20s) ───────
curl -s "$API_URL/status/$REQUEST_ID_2" | jq .


# ── SCENE 3 — Capture callback ID ────────────────────────────
CALLBACK_ID=$(curl -s "$API_URL/status/$REQUEST_ID_2" | jq -r '.callback_id')
echo "CALLBACK_ID = $CALLBACK_ID"


# ── SCENE 3 — Submit reviewer decision ───────────────────────
curl -s -X POST "$API_URL/review/$CALLBACK_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "decision":    "approved",
    "notes":       "Extended psychotherapy medically necessary given partial medication response. Meets clinical criteria for moderate MDD.",
    "reviewer_id": "DR-001"
  }' | jq .


# ── SCENE 3 — Final status ────────────────────────────────────
curl -s "$API_URL/status/$REQUEST_ID_2" | jq .
