output "kms_key_alias" {
  value = aws_kms_alias.vault_unseal.name
}

output "backup_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}

output "smtp_user" {
  value = aws_iam_user.smtp.name
}

output "smtp_host" {
  value = format("email-smtp.%s.amazonaws.com", data.aws_region.current.region)
}
