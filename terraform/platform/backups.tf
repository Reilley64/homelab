resource "aws_s3_bucket" "backups" {
  bucket = "${local.prefix}-backups"
}

resource "aws_iam_user" "backup" {
  name = "${local.prefix}-backup"
}

# restic's S3 guide grants these actions.
data "aws_iam_policy_document" "backup" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
}

resource "aws_iam_user_policy" "backup" {
  name   = "backup"
  user   = aws_iam_user.backup.name
  policy = data.aws_iam_policy_document.backup.json
}

# The nightly backup on the host saves Vault and Nomad snapshots with these.
# Consul snapshots need a management token, so Consul has no policy here.
resource "vault_policy" "backup" {
  name = "backup"

  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

resource "nomad_acl_policy" "backup" {
  name        = "backup"
  description = "Save Nomad snapshots"
  rules_hcl   = <<-EOT
    operator {
      policy = "write"
    }
  EOT
}
