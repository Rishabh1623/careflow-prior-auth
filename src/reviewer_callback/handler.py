import base64
import json
import logging

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

VALID_DECISIONS = {"approved", "denied"}


def handler(event: dict, context) -> dict:
    path_params = event.get("pathParameters") or {}
    callback_id = path_params.get("callback_id")

    if not callback_id:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "callback_id path parameter is required"}),
        }

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

    decision = str(body.get("decision", "")).lower()
    if decision not in VALID_DECISIONS:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "error": "decision must be 'approved' or 'denied'",
                "received": decision,
            }),
        }

    notes = body.get("notes", "")
    reviewer_id = body.get("reviewer_id", "unknown")

    # Result is serialized as a JSON string — orchestrator does json.loads() on callback.result()
    result_payload = json.dumps({
        "decision": decision,
        "notes": notes,
        "reviewer_id": reviewer_id,
    })

    lambda_client = boto3.client("lambda")
    try:
        lambda_client.send_durable_execution_callback_success(
            CallbackId=callback_id,
            Result=result_payload,
        )
        logger.info(
            "Resolved callback %s with decision=%s by reviewer %s",
            callback_id, decision, reviewer_id,
        )
    except lambda_client.exceptions.ResourceNotFoundException:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "error": "Callback not found — may have already been resolved or expired",
                "callback_id": callback_id,
            }),
        }
    except Exception as exc:
        logger.error("Failed to resolve callback %s: %s", callback_id, exc)
        return {
            "statusCode": 503,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"Failed to resolve callback: {exc}"}),
        }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "message": "Review decision recorded and orchestration resumed",
            "callback_id": callback_id,
            "decision": decision,
        }),
    }
