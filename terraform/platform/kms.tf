resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal"
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/homelab-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

resource "aws_iam_user" "vault_unseal" {
  name = "${local.prefix}-vault-unseal"
}

data "aws_iam_policy_document" "vault_unseal" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

resource "aws_iam_user_policy" "vault_unseal" {
  name   = "vault-unseal"
  user   = aws_iam_user.vault_unseal.name
  policy = data.aws_iam_policy_document.vault_unseal.json
}
