output "kms_key_alias" {
  value = aws_kms_alias.vault_unseal.name
}

output "backup_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}
