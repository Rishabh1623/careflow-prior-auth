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
