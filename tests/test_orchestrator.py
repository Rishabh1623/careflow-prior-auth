"""
Tests for the orchestrator Lambda handler.

Key things covered:
- evaluate_with_claude: confidence threshold, explicit escalate, schema failure
- notify_reviewer: claude_decision field written to DynamoDB (regression for fixed bug)
- save_decision: claude_decision field written on approve/deny path
- get_api_key: JSON and plain-string secret formats
- handler: approve path routing, escalate path routing
"""

import json
import os
import sys
from unittest.mock import MagicMock, patch

import pytest

orch = sys.modules["orchestrator_handler"]


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_claude_response(decision: str, confidence: float) -> MagicMock:
    payload = json.dumps({
        "decision": decision,
        "confidence": confidence,
        "reasoning": "test reasoning",
        "policy_criteria_met": ["criterion A"],
        "missing_information": [],
        "reviewer_notes": None,
    })
    resp = MagicMock()
    resp.content = [MagicMock(type="text", text=payload)]
    resp.usage = MagicMock(input_tokens=100, output_tokens=50)
    return resp


def _run_evaluate(api_response: MagicMock) -> dict:
    mock_client = MagicMock()
    mock_client.messages.create.return_value = api_response
    request = {
        "patient_id": "P1", "provider_id": "PR1",
        "diagnosis_code": "J18.9", "procedure_code": "99233",
        "request_id": "test-req",
    }
    with patch.object(orch, "Anthropic", return_value=mock_client):
        return orch.evaluate_with_claude.__original__(MagicMock(), request, "sk-test")


# ── evaluate_with_claude ──────────────────────────────────────────────────────

def test_evaluate_approve_high_confidence():
    result = _run_evaluate(_make_claude_response("APPROVE", 0.95))
    assert result["decision"] == "APPROVE"
    assert result["confidence"] == 0.95


def test_evaluate_deny_high_confidence():
    result = _run_evaluate(_make_claude_response("DENY", 0.92))
    assert result["decision"] == "DENY"


def test_evaluate_low_confidence_escalates():
    """Confidence 0.85 is below the 0.90 threshold — must override to ESCALATE."""
    result = _run_evaluate(_make_claude_response("APPROVE", 0.85))
    assert result["decision"] == "ESCALATE"


def test_evaluate_at_threshold_does_not_escalate():
    """Confidence exactly at threshold (0.90) should NOT escalate."""
    result = _run_evaluate(_make_claude_response("APPROVE", 0.90))
    assert result["decision"] == "APPROVE"


def test_evaluate_explicit_escalate_from_claude():
    result = _run_evaluate(_make_claude_response("ESCALATE", 0.60))
    assert result["decision"] == "ESCALATE"


def test_evaluate_malformed_schema_escalates():
    """Valid JSON that fails Pydantic validation → graceful ESCALATE."""
    bad_payload = json.dumps({"wrong_field": "value"})
    resp = MagicMock()
    resp.content = [MagicMock(type="text", text=bad_payload)]
    resp.usage = MagicMock(input_tokens=10, output_tokens=5)
    result = _run_evaluate(resp)
    assert result["decision"] == "ESCALATE"
    assert result["confidence"] == 0.0


def test_evaluate_invalid_json_raises():
    """Unparseable JSON from Claude propagates as ValueError."""
    resp = MagicMock()
    resp.content = [MagicMock(type="text", text="not json at all")]
    resp.usage = MagicMock(input_tokens=10, output_tokens=5)
    with pytest.raises(ValueError, match="invalid JSON"):
        _run_evaluate(resp)


# ── notify_reviewer ───────────────────────────────────────────────────────────

def test_notify_reviewer_writes_claude_decision():
    """
    Regression test: notify_reviewer must persist claude_decision='escalate'.
    This field was absent before the fix — this test catches any future reversion.
    """
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table
    mock_sns = MagicMock()

    env = {
        "REVIEWER_SNS_TOPIC_ARN": "arn:aws:sns:us-east-1:123:reviewer",
        "API_GATEWAY_URL": "https://api.example.com",
    }
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_sns), \
         patch.dict(os.environ, env):
        orch.notify_reviewer.__original__(
            MagicMock(),
            callback_id="cb-123",
            request_id="req-456",
            request={
                "patient_id": "P1", "provider_id": "PR1",
                "diagnosis_code": "J18.9", "procedure_code": "99233",
            },
        )

    call_kw = mock_table.update_item.call_args[1]
    assert "claude_decision" in call_kw["UpdateExpression"]
    assert call_kw["ExpressionAttributeValues"][":cd"] == "escalate"


def test_notify_reviewer_sets_under_review_status():
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table
    mock_sns = MagicMock()

    env = {
        "REVIEWER_SNS_TOPIC_ARN": "arn:aws:sns:us-east-1:123:reviewer",
        "API_GATEWAY_URL": "https://api.example.com",
    }
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_sns), \
         patch.dict(os.environ, env):
        orch.notify_reviewer.__original__(
            MagicMock(), "cb-123", "req-456",
            {"patient_id": "P1", "provider_id": "PR1",
             "diagnosis_code": "J18.9", "procedure_code": "99233"},
        )

    values = mock_table.update_item.call_args[1]["ExpressionAttributeValues"]
    assert values[":status"] == "UNDER_REVIEW"
    assert values[":fd"] == "ESCALATE"


# ── save_decision ─────────────────────────────────────────────────────────────

def test_save_decision_writes_claude_decision():
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table
    mock_cw = MagicMock()

    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_cw):
        orch.save_decision.__original__(
            MagicMock(),
            request_id="req-001",
            decision="APPROVE",
            reasoning="medically necessary",
            confidence=0.95,
            policy_criteria_met=["criterion A"],
            missing_information=[],
            reviewer_notes=None,
            input_tokens=100,
            output_tokens=50,
        )

    first_call = mock_table.update_item.call_args_list[0][1]
    assert "claude_decision" in first_call["UpdateExpression"]
    assert first_call["ExpressionAttributeValues"][":decision"] == "approve"


def test_save_decision_sets_approved_status():
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table

    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=MagicMock()):
        orch.save_decision.__original__(
            MagicMock(), "req-001", "APPROVE", "ok", 0.95, [], [], None, 100, 50,
        )

    first_call = mock_table.update_item.call_args_list[0][1]
    assert first_call["ExpressionAttributeValues"][":status"] == "APPROVED"


def test_save_decision_claude_decision_is_lowercase():
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table

    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=MagicMock()):
        orch.save_decision.__original__(
            MagicMock(), "req-001", "DENY", "not necessary", 0.92, [], [], None, 100, 50,
        )

    first_call = mock_table.update_item.call_args_list[0][1]
    assert first_call["ExpressionAttributeValues"][":decision"] == "deny"


def test_save_review_decision_writes_final_decision():
    """Regression: save_review_decision must overwrite final_decision from 'ESCALATE' to resolved status."""
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table

    with patch("boto3.resource", return_value=mock_ddb):
        orch.save_review_decision.__original__(
            MagicMock(),
            request_id="req-001",
            reviewer_result={"decision": "approved", "notes": "ok", "reviewer_id": "DR-001"},
        )

    call_kw = mock_table.update_item.call_args[1]
    assert "final_decision" in call_kw["UpdateExpression"]
    assert call_kw["ExpressionAttributeValues"][":fd"] == "APPROVED"


def test_save_review_decision_deny_writes_final_decision():
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table

    with patch("boto3.resource", return_value=mock_ddb):
        orch.save_review_decision.__original__(
            MagicMock(),
            request_id="req-001",
            reviewer_result={"decision": "denied", "notes": "not needed", "reviewer_id": "DR-002"},
        )

    call_kw = mock_table.update_item.call_args[1]
    assert call_kw["ExpressionAttributeValues"][":fd"] == "DENIED"


def test_save_decision_deny_sets_denied_status():
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table

    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=MagicMock()):
        orch.save_decision.__original__(
            MagicMock(), "req-001", "DENY", "not necessary", 0.92, [], [], None, 100, 50,
        )

    first_call = mock_table.update_item.call_args_list[0][1]
    assert first_call["ExpressionAttributeValues"][":status"] == "DENIED"


# ── get_api_key ───────────────────────────────────────────────────────────────

def test_get_api_key_json_format():
    mock_sm = MagicMock()
    mock_sm.get_secret_value.return_value = {
        "SecretString": json.dumps({"api_key": "sk-ant-json"})
    }
    with patch("boto3.client", return_value=mock_sm):
        result = orch.get_api_key.__original__(MagicMock())
    assert result == "sk-ant-json"


def test_get_api_key_plain_string():
    mock_sm = MagicMock()
    mock_sm.get_secret_value.return_value = {"SecretString": "sk-ant-plain"}
    with patch("boto3.client", return_value=mock_sm):
        result = orch.get_api_key.__original__(MagicMock())
    assert result == "sk-ant-plain"


# ── handler routing ───────────────────────────────────────────────────────────

def test_handler_approve_path():
    mock_ctx = MagicMock()
    mock_ctx.step.side_effect = [
        {"request_id": "req-001", "patient_id": "P1", "provider_id": "PR1",
         "diagnosis_code": "J18.9", "procedure_code": "99233", "status": "PENDING"},
        "sk-test",                                          # get_api_key
        {"decision": "APPROVE", "confidence": 0.95,        # evaluate_with_claude
         "reasoning": "ok", "policy_criteria_met": [],
         "missing_information": [], "reviewer_notes": None,
         "input_tokens": 100, "output_tokens": 50},
        None,                                               # save_decision
        None,                                               # notify_decision
    ]

    result = orch.handler({"request_id": "req-001"}, mock_ctx)

    assert result["decision"] == "APPROVE"
    assert result["decided_by"] == "claude_ai"
    mock_ctx.create_callback.assert_not_called()


def test_handler_escalate_path():
    mock_ctx = MagicMock()
    mock_callback = MagicMock()
    mock_callback.callback_id = "cb-test"
    mock_callback.result.return_value = json.dumps(
        {"decision": "approved", "notes": "ok", "reviewer_id": "DR-001"}
    )
    mock_ctx.create_callback.return_value = mock_callback
    mock_ctx.step.side_effect = [
        {"request_id": "req-002", "patient_id": "P1", "provider_id": "PR1",
         "diagnosis_code": "J18.9", "procedure_code": "99233", "status": "PENDING"},
        "sk-test",
        {"decision": "ESCALATE", "confidence": 0.70, "reasoning": "unclear",
         "policy_criteria_met": [], "missing_information": ["more info needed"],
         "reviewer_notes": None, "input_tokens": 100, "output_tokens": 50},
        None,   # notify_reviewer
        None,   # save_review_decision
        None,   # notify_final_decision
    ]

    result = orch.handler({"request_id": "req-002"}, mock_ctx)

    assert result["decision"] == "approved"
    assert result["decided_by"] == "human_reviewer"
    assert result["reviewer_id"] == "DR-001"
    mock_ctx.create_callback.assert_called_once_with(name="human-review")


def test_handler_missing_request_id_raises():
    with pytest.raises(ValueError, match="request_id"):
        orch.handler({}, MagicMock())
