import base64
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "careflow-prior-auth-requests")
ORCHESTRATOR_FUNCTION_NAME = os.environ.get(
    "ORCHESTRATOR_FUNCTION_NAME", "careflow-dev-orchestrator"
)
TTL_DAYS = 90

REQUIRED_FIELDS = ["patient_id", "provider_id", "diagnosis_code", "procedure_code"]


def _validate_body(body: dict) -> list:
    return [f"Missing required field: {f}" for f in REQUIRED_FIELDS if not body.get(f)]


def handler(event: dict, context) -> dict:
    try:
        body_str = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            body_str = base64.b64decode(body_str).decode("utf-8")
        body = json.loads(body_str)
    except Exception as exc:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"Invalid JSON body: {exc}"}),
        }

    errors = _validate_body(body)
    if errors:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Validation failed", "details": errors}),
        }

    request_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    ttl = int(time.time()) + TTL_DAYS * 86400

    item = {
        "request_id": request_id,
        "patient_id": body["patient_id"],
        "provider_id": body["provider_id"],
        "diagnosis_code": body["diagnosis_code"],
        "procedure_code": body["procedure_code"],
        "status": "PENDING",
        "created_at": now,
        "submitted_at": now,  # GSI sort key for DecisionDateIndex
        "updated_at": now,
        "ttl": ttl,
    }

    clinical_notes = body.get("clinical_notes", "")
    if clinical_notes:
        item["clinical_notes"] = clinical_notes

    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE)

    try:
        table.put_item(Item=item)
        logger.info("Created request %s in DynamoDB", request_id)
    except Exception as exc:
        logger.error("DynamoDB PutItem failed: %s", exc)
        return {
            "statusCode": 503,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Failed to persist request"}),
        }

    lambda_client = boto3.client("lambda")
    try:
        lambda_client.invoke(
            FunctionName=ORCHESTRATOR_FUNCTION_NAME,
            InvocationType="Event",  # async — fire and forget
            Payload=json.dumps({"request_id": request_id}).encode("utf-8"),
        )
        logger.info("Invoked orchestrator async for request_id=%s", request_id)
    except Exception as exc:
        logger.error("Failed to invoke orchestrator: %s", exc)
        return {
            "statusCode": 202,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "request_id": request_id,
                "status": "PENDING",
                "warning": "Orchestration could not be started automatically",
            }),
        }

    return {
        "statusCode": 202,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "request_id": request_id,
            "status": "PENDING",
            "message": "Prior authorization request received and processing initiated",
        }),
    }
