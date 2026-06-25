"""Tests for the submission Lambda handler."""

import json
import sys
from unittest.mock import MagicMock, patch

subm = sys.modules["submission_handler"]

VALID_BODY = {
    "patient_id": "PAT-001",
    "provider_id": "PROV-001",
    "diagnosis_code": "J18.9",
    "procedure_code": "99233",
}


def _event(body: dict, base64_encode: bool = False) -> dict:
    body_str = json.dumps(body)
    if base64_encode:
        import base64
        return {"body": base64.b64encode(body_str.encode()).decode(), "isBase64Encoded": True}
    return {"body": body_str, "isBase64Encoded": False}


def _patched_aws(table_error=None, lambda_error=None):
    mock_table = MagicMock()
    if table_error:
        mock_table.put_item.side_effect = table_error
    mock_ddb = MagicMock()
    mock_ddb.Table.return_value = mock_table

    mock_lambda = MagicMock()
    if lambda_error:
        mock_lambda.invoke.side_effect = lambda_error

    return mock_ddb, mock_lambda, mock_table


# ── validation ────────────────────────────────────────────────────────────────

def test_valid_request_returns_202():
    mock_ddb, mock_lambda, mock_table = _patched_aws()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = subm.handler(_event(VALID_BODY), None)

    assert resp["statusCode"] == 202
    body = json.loads(resp["body"])
    assert "request_id" in body
    assert body["status"] == "PENDING"
    mock_table.put_item.assert_called_once()


def test_missing_one_field_returns_400():
    body = {k: v for k, v in VALID_BODY.items() if k != "patient_id"}
    resp = subm.handler(_event(body), None)
    assert resp["statusCode"] == 400
    details = json.loads(resp["body"])["details"]
    assert any("patient_id" in d for d in details)


def test_all_fields_missing_returns_400_with_four_errors():
    resp = subm.handler(_event({}), None)
    assert resp["statusCode"] == 400
    assert len(json.loads(resp["body"])["details"]) == 4


def test_invalid_json_body_returns_400():
    resp = subm.handler({"body": "not-json", "isBase64Encoded": False}, None)
    assert resp["statusCode"] == 400


def test_base64_encoded_body_accepted():
    mock_ddb, mock_lambda, _ = _patched_aws()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = subm.handler(_event(VALID_BODY, base64_encode=True), None)
    assert resp["statusCode"] == 202


# ── error paths ───────────────────────────────────────────────────────────────

def test_dynamodb_failure_returns_503():
    mock_ddb, mock_lambda, _ = _patched_aws(table_error=Exception("DDB down"))
    with patch("boto3.resource", return_value=mock_ddb):
        resp = subm.handler(_event(VALID_BODY), None)
    assert resp["statusCode"] == 503


def test_orchestrator_invoke_failure_returns_202_with_warning():
    mock_ddb, mock_lambda, _ = _patched_aws(lambda_error=Exception("Lambda down"))
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        resp = subm.handler(_event(VALID_BODY), None)
    assert resp["statusCode"] == 202
    assert "warning" in json.loads(resp["body"])


# ── DynamoDB item content ─────────────────────────────────────────────────────

def test_dynamodb_item_has_required_fields():
    mock_ddb, mock_lambda, mock_table = _patched_aws()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        subm.handler(_event(VALID_BODY), None)

    item = mock_table.put_item.call_args[1]["Item"]
    for field in ("request_id", "patient_id", "provider_id",
                  "diagnosis_code", "procedure_code", "status", "ttl"):
        assert field in item, f"missing field: {field}"
    assert item["status"] == "PENDING"


def test_clinical_notes_included_when_provided():
    mock_ddb, mock_lambda, mock_table = _patched_aws()
    body = {**VALID_BODY, "clinical_notes": "Patient has persistent cough"}
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        subm.handler(_event(body), None)

    item = mock_table.put_item.call_args[1]["Item"]
    assert item.get("clinical_notes") == "Patient has persistent cough"


def test_clinical_notes_absent_when_not_provided():
    mock_ddb, mock_lambda, mock_table = _patched_aws()
    with patch("boto3.resource", return_value=mock_ddb), \
         patch("boto3.client", return_value=mock_lambda):
        subm.handler(_event(VALID_BODY), None)

    item = mock_table.put_item.call_args[1]["Item"]
    assert "clinical_notes" not in item
