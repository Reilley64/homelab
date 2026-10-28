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
