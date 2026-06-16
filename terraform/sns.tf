resource "aws_sns_topic" "reviewer" {
  name = "${local.name_prefix}-reviewer-notifications"
  tags = local.common_tags
}

resource "aws_sns_topic" "decisions" {
  name = "${local.name_prefix}-decision-notifications"
  tags = local.common_tags
}
