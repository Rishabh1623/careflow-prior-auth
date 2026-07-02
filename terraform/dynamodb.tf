resource "aws_kms_key" "dynamodb" {
  description             = "CareFlow DynamoDB encryption key - protects PHI fields at rest"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "careflow-${var.environment}-dynamodb-key"
  })
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/careflow-${var.environment}-dynamodb"
  target_key_id = aws_kms_key.dynamodb.key_id
}

resource "aws_dynamodb_table" "requests" {
  name                        = "${local.name_prefix}-prior-auth-requests"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "request_id"
  deletion_protection_enabled = true

  attribute {
    name = "request_id"
    type = "S"
  }

  # GSI attributes — Feature 5: DecisionDateIndex
  attribute {
    name = "final_decision"
    type = "S"
  }

  attribute {
    name = "submitted_at"
    type = "S"
  }

  global_secondary_index {
    name            = "DecisionDateIndex"
    hash_key        = "final_decision"
    range_key       = "submitted_at"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-prior-auth-requests"
  })
}

# Feature 4: Callback idempotency table — prevents duplicate callback resolution
resource "aws_dynamodb_table" "callback_idempotency" {
  name                        = "${local.name_prefix}-callback-idempotency"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "callback_id"
  deletion_protection_enabled = true

  attribute {
    name = "callback_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-callback-idempotency"
  })
}
