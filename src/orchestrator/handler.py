import json
import logging
import os
from datetime import datetime, timezone

import boto3
from anthropic import Anthropic

from aws_durable_execution_sdk_python import (
    DurableContext,
    StepContext,
    durable_execution,
    durable_step,
)

class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        data = {"level": record.levelname, "message": record.getMessage()}
        for key in ("request_id", "callback_id"):
            val = getattr(record, key, None)
            if val is not None:
                data[key] = val
        return json.dumps(data)


logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
_h = logging.StreamHandler()
_h.setFormatter(_JsonFormatter())
logger.addHandler(_h)
logger.propagate = False

DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "careflow-prior-auth-requests")
SECRET_NAME = "careflow/anthropic-api-key"
MODEL_ID = "claude-sonnet-4-6"

# Prompt kept module-level (pure constant — safe outside @durable_step)
_SYSTEM_PROMPT = """You are an expert prior authorization evaluator for a healthcare organization.
Evaluate prior authorization requests based on clinical criteria, payer policies, and medical necessity guidelines.

Respond with a JSON object only — no other text, no markdown fences. The JSON must have exactly these fields:
- "decision": one of "approve", "deny", or "escalate"
- "reasoning": clear clinical explanation of your decision (string)
- "confidence": your confidence level from 0.0 to 1.0 (float)
- "criteria_met": list of clinical criteria that support approval (list of strings)
- "criteria_failed": list of clinical criteria that are not met (list of strings)

Use "escalate" when:
- Clinical information is insufficient for a clear decision
- The case involves unusual, high-risk, or experimental circumstances requiring human review
- Confidence is below 0.75
- The diagnosis/procedure combination is rare or outside standard guidelines"""


@durable_step
def fetch_request(ctx: StepContext, request_id: str) -> dict:
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE)
    response = table.get_item(Key={"request_id": request_id})
    item = response.get("Item")
    if not item:
        raise ValueError(f"Request {request_id} not found in DynamoDB")
    logger.info("Fetched request (status=%s)", item.get("status"), extra={"request_id": request_id})
    return item


@durable_step
def get_api_key(ctx: StepContext) -> str:
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=SECRET_NAME)
    secret = response["SecretString"]
    try:
        return json.loads(secret)["api_key"]
    except (json.JSONDecodeError, KeyError):
        return secret


@durable_step
def evaluate_with_claude(ctx: StepContext, request: dict, api_key: str) -> dict:
    client = Anthropic(api_key=api_key)

    user_message = (
        f"Please evaluate this prior authorization request:\n\n"
        f"Patient ID: {request.get('patient_id')}\n"
        f"Provider ID: {request.get('provider_id')}\n"
        f"Diagnosis Code (ICD-10): {request.get('diagnosis_code')}\n"
        f"Procedure Code (CPT): {request.get('procedure_code')}\n"
        f"Request ID: {request.get('request_id')}\n"
        f"Submitted: {request.get('created_at')}\n\n"
        "Evaluate whether this procedure is medically necessary for the given diagnosis. "
        "Respond with only the JSON object described in the system prompt."
    )

    response = client.messages.create(
        model=MODEL_ID,
        max_tokens=1024,
        temperature=0,
        system=_SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_message}],
    )

    text_content = next(
        (block.text for block in response.content if block.type == "text"),
        None,
    )
    if not text_content:
        raise ValueError("Claude returned no text content")

    try:
        result = json.loads(text_content)
    except json.JSONDecodeError as exc:
        logger.error(
            "Claude response not valid JSON: %s", text_content,
            extra={"request_id": request.get("request_id")},
        )
        raise ValueError(f"Claude returned invalid JSON: {exc}") from exc

    required = {"decision", "reasoning", "confidence", "criteria_met", "criteria_failed"}
    missing = required - result.keys()
    if missing:
        raise ValueError(f"Claude response missing fields: {missing}")

    if result["decision"] not in ("approve", "deny", "escalate"):
        raise ValueError(f"Unexpected decision value: {result['decision']!r}")

    logger.info(
        "Claude decision=%s confidence=%s",
        result["decision"], result["confidence"],
        extra={"request_id": request.get("request_id")},
    )
    return result


@durable_step
def save_decision(
    ctx: StepContext,
    request_id: str,
    decision: str,
    reasoning: str,
    confidence: float,
    criteria_met: list,
    criteria_failed: list,
) -> None:
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE)
    status = "APPROVED" if decision == "approve" else "DENIED"
    updated_at = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"request_id": request_id},
        UpdateExpression=(
            "SET #s = :status, claude_decision = :decision, "
            "claude_reasoning = :reasoning, claude_confidence = :confidence, "
            "criteria_met = :cm, criteria_failed = :cf, updated_at = :ua"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": status,
            ":decision": decision,
            ":reasoning": reasoning,
            ":confidence": str(confidence),  # str avoids DynamoDB decimal.Inexact
            ":cm": criteria_met,
            ":cf": criteria_failed,
            ":ua": updated_at,
        },
    )
    logger.info("Saved decision %s", status, extra={"request_id": request_id})


@durable_step
def notify_decision(
    ctx: StepContext,
    request_id: str,
    decision: str,
    reasoning: str,
) -> None:
    sns = boto3.client("sns")
    topic_arn = os.environ["DECISION_SNS_TOPIC_ARN"]
    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps({
            "event": "prior_auth_decision",
            "request_id": request_id,
            "decision": decision,
            "reasoning": reasoning,
            "decided_by": "claude_ai",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }),
        Subject=f"Prior Auth Decision: {decision.upper()} - {request_id}",
        MessageAttributes={
            "decision": {"DataType": "String", "StringValue": decision},
        },
    )
    logger.info("Published decision %s to SNS", decision, extra={"request_id": request_id})


@durable_step
def notify_reviewer(
    ctx: StepContext,
    callback_id: str,
    request_id: str,
    request: dict,
) -> None:
    updated_at = datetime.now(timezone.utc).isoformat()

    # Persist UNDER_REVIEW status + callback_id atomically with notification
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE)
    table.update_item(
        Key={"request_id": request_id},
        UpdateExpression="SET #s = :status, callback_id = :cb, updated_at = :ua",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "UNDER_REVIEW",
            ":cb": callback_id,
            ":ua": updated_at,
        },
    )

    sns = boto3.client("sns")
    topic_arn = os.environ["REVIEWER_SNS_TOPIC_ARN"]
    api_url = os.environ.get("API_GATEWAY_URL", "https://api.example.com")
    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps({
            "event": "prior_auth_escalation",
            "request_id": request_id,
            "callback_id": callback_id,
            "patient_id": request.get("patient_id"),
            "provider_id": request.get("provider_id"),
            "diagnosis_code": request.get("diagnosis_code"),
            "procedure_code": request.get("procedure_code"),
            "review_url": f"{api_url}/review/{callback_id}",
            "timestamp": updated_at,
        }),
        Subject=f"Prior Auth Review Required - {request_id}",
    )
    logger.info(
        "Escalated request to human review",
        extra={"request_id": request_id, "callback_id": callback_id},
    )


@durable_step
def save_review_decision(
    ctx: StepContext,
    request_id: str,
    reviewer_result: dict,
) -> None:
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE)
    decision = reviewer_result.get("decision", "")
    status = "APPROVED" if decision == "approved" else "DENIED"
    updated_at = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"request_id": request_id},
        UpdateExpression=(
            "SET #s = :status, reviewer_decision = :decision, "
            "reviewer_notes = :notes, reviewer_id = :rid, updated_at = :ua"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": status,
            ":decision": decision,
            ":notes": reviewer_result.get("notes", ""),
            ":rid": reviewer_result.get("reviewer_id", "unknown"),
            ":ua": updated_at,
        },
    )
    logger.info("Saved reviewer decision %s", status, extra={"request_id": request_id})


@durable_step
def notify_final_decision(
    ctx: StepContext,
    request_id: str,
    reviewer_result: dict,
) -> None:
    sns = boto3.client("sns")
    topic_arn = os.environ["DECISION_SNS_TOPIC_ARN"]
    decision = reviewer_result.get("decision", "")
    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps({
            "event": "prior_auth_decision",
            "request_id": request_id,
            "decision": decision,
            "notes": reviewer_result.get("notes", ""),
            "decided_by": "human_reviewer",
            "reviewer_id": reviewer_result.get("reviewer_id", "unknown"),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }),
        Subject=f"Prior Auth Final Decision: {decision.upper()} - {request_id}",
        MessageAttributes={
            "decision": {"DataType": "String", "StringValue": decision},
        },
    )
    logger.info("Published final decision %s", decision, extra={"request_id": request_id})


@durable_execution
def handler(event: dict, context: DurableContext) -> dict:
    request_id = event.get("request_id")
    if not request_id:
        raise ValueError("event must contain 'request_id'")

    logger.info("Starting orchestration", extra={"request_id": request_id})

    request = context.step(fetch_request(request_id))
    api_key = context.step(get_api_key())
    claude_result = context.step(evaluate_with_claude(request, api_key))

    decision = claude_result["decision"]

    if decision in ("approve", "deny"):
        context.step(
            save_decision(
                request_id,
                decision,
                claude_result["reasoning"],
                claude_result["confidence"],
                claude_result.get("criteria_met", []),
                claude_result.get("criteria_failed", []),
            )
        )
        context.step(notify_decision(request_id, decision, claude_result["reasoning"]))
        logger.info("Auto-decided %s", decision, extra={"request_id": request_id})
        return {
            "request_id": request_id,
            "decision": decision,
            "decided_by": "claude_ai",
            "confidence": claude_result["confidence"],
        }

    # escalate — suspend at zero compute cost until human reviewer responds
    callback = context.create_callback(name="human-review")
    context.step(notify_reviewer(callback.callback_id, request_id, request))

    logger.info(
        "Suspending orchestration pending human review",
        extra={"request_id": request_id, "callback_id": callback.callback_id},
    )
    reviewer_result = json.loads(callback.result())  # execution suspends here

    context.step(save_review_decision(request_id, reviewer_result))
    context.step(notify_final_decision(request_id, reviewer_result))

    logger.info(
        "Human review complete decision=%s", reviewer_result.get("decision"),
        extra={"request_id": request_id, "callback_id": callback.callback_id},
    )
    return {
        "request_id": request_id,
        "decision": reviewer_result.get("decision"),
        "decided_by": "human_reviewer",
        "reviewer_id": reviewer_result.get("reviewer_id"),
    }
