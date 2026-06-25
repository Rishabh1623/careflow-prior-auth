"""Tests for the reviewer callback Lambda handler."""

import json
import sys
from unittest.mock import MagicMock, patch

rcb = sys.modules["reviewer_callback_handler"]

CB_ID = "test-callback-id-abc123"

VALID_BODY = {"decision": "approved", "notes": "Medically necessary", "reviewer_id": "DR-001"}


def _event(body: dict, callback_id: str = CB_ID, base64_encode: bool = False) -> dict:
    body_str = json.dumps(body)
    if base64_encode:
        import base64
        return {
            "pathParameters": {"callback_id": callback_id},
            "body": base64.b64encode(body_str.encode()).decode(),
            "isBase64Encoded": True,
        }
    return {
        "pathParameters": {"callback_id": callback_id},
        "body": body_str,
        "isBase64Encoded": False,
    }


def _make_aws_mocks(duplicate=False, callback_missing=False):
    """Build mock DynamoDB resource and Lambda client with configurable failure modes."""
    # DynamoDB
    ConditionalCheckFailed = type("ConditionalCheckFailedException", (Exception,), {})
    mock_table = MagicMock()
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table
    mock_ddb.meta.client.exceptions.ConditionalCheckFailedException = ConditionalCheckFailed
    if duplicate:
        mock_table.put_item.side_effect = ConditionalCheckFailed("already resolved")

    # Lambda
    ResourceNotFound = type("ResourceNotFoundException", (Exception,), {})
    mock_lambda = MagicMock()
    mock_lambda.exceptions.ResourceNotFoundException = ResourceNotFound
    if callback_missing:
        mock_lambda.send_durable_execution_callback_success.side_effect = ResourceNotFound("not found")

    return mock_ddb, mock_lambda


# ── validation ────────────────────────────────────────────────────────────────

def test_missing_callback_id_returns_400():
    resp = rcb.handler({"pathParameters": None, "body": json.dumps(VALID_BODY)}, None)
    assert resp["statusCode"] == 400


def test_invalid_decision_value_returns_400():
    resp = rcb.handler(_event({"decision": "maybe", "reviewer_id": "DR-1"}), None)
    assert resp["statusCode"] == 400
    body = json.loads(resp["body"])
    assert "approved" in body["error"] or "denied" in body["error"]


def test_invalid_json_body_returns_400():
    resp = rcb.handler(
        {"pathParameters": {"callback_id": CB_ID}, "body": "not-json", "isBase64Encoded": False},
        None,
    )
    assert resp["statusCode"] == 400


# ── happy path ────────────────────────────────────────────────────────────────

def test_valid_approval_returns_200():
    mock_ddb, mock_lambda = _make_aws_mocks()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = rcb.handler(_event(VALID_BODY), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["decision"] == "approved"
    assert body["callback_id"] == CB_ID


def test_valid_denial_returns_200():
    mock_ddb, mock_lambda = _make_aws_mocks()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = rcb.handler(_event({"decision": "denied", "reviewer_id": "DR-002"}), None)

    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["decision"] == "denied"


def test_decision_is_lowercased():
    """Handler must normalise uppercase 'APPROVED' to 'approved'."""
    mock_ddb, mock_lambda = _make_aws_mocks()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = rcb.handler(_event({"decision": "APPROVED", "reviewer_id": "DR-1"}), None)

    assert resp["statusCode"] == 200
    call_kw = mock_lambda.send_durable_execution_callback_success.call_args[1]
    result = json.loads(call_kw["Result"])
    assert result["decision"] == "approved"


def test_callback_payload_sent_to_lambda():
    """Orchestrator receives the reviewer's decision, notes, and reviewer_id."""
    mock_ddb, mock_lambda = _make_aws_mocks()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        rcb.handler(_event(VALID_BODY), None)

    call_kw = mock_lambda.send_durable_execution_callback_success.call_args[1]
    assert call_kw["CallbackId"] == CB_ID
    payload = json.loads(call_kw["Result"])
    assert payload["decision"] == "approved"
    assert payload["notes"] == "Medically necessary"
    assert payload["reviewer_id"] == "DR-001"


def test_base64_encoded_body_accepted():
    mock_ddb, mock_lambda = _make_aws_mocks()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = rcb.handler(_event(VALID_BODY, base64_encode=True), None)
    assert resp["statusCode"] == 200


# ── error paths ───────────────────────────────────────────────────────────────

def test_duplicate_callback_returns_409():
    mock_ddb, mock_lambda = _make_aws_mocks(duplicate=True)
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = rcb.handler(_event(VALID_BODY), None)

    assert resp["statusCode"] == 409
    mock_lambda.send_durable_execution_callback_success.assert_not_called()


def test_callback_not_found_returns_404():
    mock_ddb, mock_lambda = _make_aws_mocks(callback_missing=True)
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = rcb.handler(_event(VALID_BODY), None)

    assert resp["statusCode"] == 404
