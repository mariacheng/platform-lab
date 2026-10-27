terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags { tags = { project = "platform-lab", owner = var.owner } }
}

variable "region" { default = "us-east-1" }
variable "owner" { type = string }
variable "budget_email" { type = string }
variable "ci_provider" {
  description = "Which CI system deploys: github or bitbucket."
  type        = string
  default     = "github"
  validation {
    condition     = contains(["github", "bitbucket"], var.ci_provider)
    error_message = "ci_provider must be \"github\" or \"bitbucket\"."
  }
}
variable "github_repo" {
  description = "GitHub owner/repo allowed to deploy, e.g. maria/platform-lab."
  type        = string
  default     = null
}
variable "bitbucket_workspace" {
  type    = string
  default = null
}
variable "bitbucket_oidc_audience" {
  type    = string
  default = null
}

data "aws_caller_identity" "me" {}

locals {
  bitbucket_issuer = "api.bitbucket.org/2.0/workspaces/${coalesce(var.bitbucket_workspace, "unset")}/pipelines-config/identity/oidc"
  oidc = {
    github = {
      issuer   = "token.actions.githubusercontent.com"
      audience = "sts.amazonaws.com"
    }
    bitbucket = {
      issuer   = local.bitbucket_issuer
      audience = coalesce(var.bitbucket_oidc_audience, "unset")
    }
  }
  ci = local.oidc[var.ci_provider]
}

resource "aws_budgets_budget" "lab" {
  name         = "platform-lab-monthly"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "platform-lab-artifacts-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-lab-data"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
  }
}

resource "aws_iam_openid_connect_provider" "ci" {
  url            = "https://${local.ci.issuer}"
  client_id_list = [local.ci.audience]
  lifecycle {
    precondition {
      condition     = var.ci_provider != "github" || var.github_repo != null
      error_message = "Set github_repo (owner/repo) when ci_provider is github."
    }
    precondition {
      condition     = var.ci_provider != "bitbucket" || (var.bitbucket_workspace != null && var.bitbucket_oidc_audience != null)
      error_message = "Set bitbucket_workspace and bitbucket_oidc_audience when ci_provider is bitbucket."
    }
  }
}

data "aws_iam_policy_document" "ci_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.ci.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.ci.issuer}:aud"
      values   = [local.ci.audience]
    }
    dynamic "condition" {
      for_each = var.ci_provider == "github" ? [var.github_repo] : []
      content {
        test     = "StringEquals"
        variable = "${local.ci.issuer}:sub"
        values   = ["repo:${condition.value}:ref:refs/heads/main"]
      }
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "platform-lab-ci"
  assume_role_policy = data.aws_iam_policy_document.ci_trust.json
}

data "aws_iam_policy_document" "ci_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci_access.json
}

output "artifacts_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "ci_role_arn" { value = aws_iam_role.ci.arn }
