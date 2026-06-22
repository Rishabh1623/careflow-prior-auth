resource "aws_sns_topic" "reviewer" {
  name = "${local.name_prefix}-reviewer-notifications"
  tags = local.common_tags
}

resource "aws_sns_topic" "decisions" {
  name = "${local.name_prefix}-decision-notifications"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "reviewer_email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.reviewer.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sns_topic_subscription" "decisions_email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.decisions.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
