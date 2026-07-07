import json
import logging
import os

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "careflow-prior-auth-requests")

RESOLVED_STATUSES = {"APPROVED", "DENIED"}


def handler(event: dict, context) -> dict:
    path_params = event.get("pathParameters") or {}
    request_id = path_params.get("request_id")

    if not request_id:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "request_id path parameter is required"}),
        }

    try:
        dynamodb = boto3.resource("dynamodb")
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.get_item(Key={"request_id": request_id})
    except Exception as exc:
        logger.error("DynamoDB error fetching request_id=%s: %s", request_id, exc)
        return {
            "statusCode": 503,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Service temporarily unavailable"}),
        }

    item = response.get("Item")

    if not item:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": f"Request {request_id} not found"}),
        }

    status = item.get("status")
    body = {"request_id": item["request_id"], "status": status}

    if item.get("final_decision"):
        body["final_decision"] = item["final_decision"]
    if item.get("claude_decision"):
        body["ai_decision"] = item["claude_decision"]
    if item.get("claude_confidence"):
        body["ai_confidence"] = item["claude_confidence"]
    if item.get("callback_id"):
        body["callback_id"] = item["callback_id"]
    if item.get("submitted_at"):
        body["submitted_at"] = item["submitted_at"]
    if status in RESOLVED_STATUSES and item.get("updated_at"):
        body["resolved_at"] = item["updated_at"]
    if item.get("reviewer_id"):
        body["human_reviewer"] = item["reviewer_id"]

    logger.info("Status check for request_id=%s status=%s", request_id, status)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
