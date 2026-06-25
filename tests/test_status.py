"""Tests for the status Lambda handler."""

import json
import sys
from unittest.mock import MagicMock, patch

status = sys.modules["status_handler"]

REQUEST_ID = "test-request-id-abc123"

_BASE_ITEM = {
    "request_id": REQUEST_ID,
    "status": "APPROVED",
    "submitted_at": "2026-06-25T00:27:36+00:00",
    "updated_at": "2026-06-25T00:30:00+00:00",
    "claude_decision": "escalate",
    "claude_confidence": "0.85",
    "final_decision": "ESCALATE",
    "reviewer_id": "DR-001",
    # fields that must NOT appear in the response
    "patient_id": "PAT-001",
    "provider_id": "PROV-001",
    "diagnosis_code": "J18.9",
    "procedure_code": "99233",
    "clinical_notes": "Patient has a cough",
    "claude_reasoning": "Confidence below threshold",
    "callback_id": "cb-abc",
    "ttl": 1790123256,
}


def _event(request_id=REQUEST_ID):
    return {"pathParameters": {"request_id": request_id}}


def _mock_table(item=None):
    mock_table = MagicMock()
    mock_table.get_item.return_value = {"Item": item} if item is not None else {}
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table
    return mock_ddb


# ── found / not found ─────────────────────────────────────────────────────────

def test_found_request_returns_200():
    with patch("boto3.resource", return_value=_mock_table(_BASE_ITEM)):
        resp = status.handler(_event(), None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["request_id"] == REQUEST_ID
    assert body["status"] == "APPROVED"


def test_not_found_returns_404():
    with patch("boto3.resource", return_value=_mock_table(None)):
        resp = status.handler(_event("nonexistent-id"), None)
    assert resp["statusCode"] == 404
    assert "not found" in json.loads(resp["body"])["error"].lower()


def test_dynamodb_error_returns_503():
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value.get_item.side_effect = Exception("connection timeout")
    with patch("boto3.resource", return_value=mock_ddb):
        resp = status.handler(_event(), None)
    assert resp["statusCode"] == 503
    assert "error" in json.loads(resp["body"])


def test_missing_request_id_returns_400():
    resp = status.handler({"pathParameters": None}, None)
    assert resp["statusCode"] == 400


# ── field mapping ─────────────────────────────────────────────────────────────

def test_field_name_mapping():
    """claude_decision → ai_decision, claude_confidence → ai_confidence."""
    with patch("boto3.resource", return_value=_mock_table(_BASE_ITEM)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert body["ai_decision"] == "escalate"
    assert body["ai_confidence"] == "0.85"
    assert "claude_decision" not in body
    assert "claude_confidence" not in body


def test_pii_and_clinical_fields_excluded():
    """patient_id, provider_id, diagnosis_code, procedure_code, clinical_notes must not appear."""
    with patch("boto3.resource", return_value=_mock_table(_BASE_ITEM)):
        body = json.loads(status.handler(_event(), None)["body"])
    for field in ("patient_id", "provider_id", "diagnosis_code",
                  "procedure_code", "clinical_notes", "claude_reasoning",
                  "callback_id", "ttl"):
        assert field not in body, f"field '{field}' must not be returned"


def test_human_reviewer_field_mapped():
    with patch("boto3.resource", return_value=_mock_table(_BASE_ITEM)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert body["human_reviewer"] == "DR-001"
    assert "reviewer_id" not in body


# ── resolved_at logic ─────────────────────────────────────────────────────────

def test_resolved_at_present_when_approved():
    with patch("boto3.resource", return_value=_mock_table(_BASE_ITEM)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert body["resolved_at"] == "2026-06-25T00:30:00+00:00"


def test_resolved_at_present_when_denied():
    item = {**_BASE_ITEM, "status": "DENIED"}
    with patch("boto3.resource", return_value=_mock_table(item)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert "resolved_at" in body


def test_resolved_at_absent_when_pending():
    item = {**_BASE_ITEM, "status": "PENDING"}
    with patch("boto3.resource", return_value=_mock_table(item)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert "resolved_at" not in body


def test_resolved_at_absent_when_under_review():
    item = {**_BASE_ITEM, "status": "UNDER_REVIEW"}
    with patch("boto3.resource", return_value=_mock_table(item)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert "resolved_at" not in body


# ── optional fields absent when not set ──────────────────────────────────────

def test_optional_fields_omitted_when_absent():
    """A minimal PENDING item should not include ai_decision, human_reviewer, etc."""
    minimal = {"request_id": REQUEST_ID, "status": "PENDING",
                "submitted_at": "2026-06-25T00:27:36+00:00"}
    with patch("boto3.resource", return_value=_mock_table(minimal)):
        body = json.loads(status.handler(_event(), None)["body"])
    assert "ai_decision" not in body
    assert "ai_confidence" not in body
    assert "human_reviewer" not in body
    assert "final_decision" not in body
    assert "resolved_at" not in body
