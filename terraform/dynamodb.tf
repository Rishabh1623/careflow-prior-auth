resource "aws_dynamodb_table" "requests" {
  name         = "careflow-prior-auth-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.common_tags, {
    Name = "careflow-prior-auth-requests"
  })
}
