# Outbound mail for the services through Amazon SES. Services send over SMTP as
# the smtp IAM user, whose access key and SMTP password are made by
# scripts/ses-smtp-credentials.py so they stay out of the state.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "cloudflare_zone" "domain" {
  filter = {
    name = local.domain
  }
}

resource "aws_sesv2_email_identity" "domain" {
  email_identity = local.domain
}

# Bounces go to mail.{domain}, so SPF passes and aligns with the From domain.
resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  email_identity   = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain = format("mail.%s", local.domain)
}

resource "cloudflare_dns_record" "ses_dkim" {
  count = 3

  zone_id = data.cloudflare_zone.domain.id
  name    = format("%s._domainkey.%s", aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index], local.domain)
  type    = "CNAME"
  content = format("%s.dkim.amazonses.com", aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index])
  ttl     = 1
  comment = "managed by terraform"
}

resource "cloudflare_dns_record" "ses_mail_from_mx" {
  zone_id  = data.cloudflare_zone.domain.id
  name     = aws_sesv2_email_identity_mail_from_attributes.domain.mail_from_domain
  type     = "MX"
  content  = format("feedback-smtp.%s.amazonses.com", data.aws_region.current.region)
  priority = 10
  ttl      = 1
  comment  = "managed by terraform"
}

resource "cloudflare_dns_record" "ses_mail_from_spf" {
  zone_id = data.cloudflare_zone.domain.id
  name    = aws_sesv2_email_identity_mail_from_attributes.domain.mail_from_domain
  type    = "TXT"
  content = "\"v=spf1 include:amazonses.com ~all\""
  ttl     = 1
  comment = "managed by terraform"
}

# p=none asks receivers to take no action yet. SES is the domain's only sender,
# so this can move to p=quarantine once mail is seen passing DKIM.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = data.cloudflare_zone.domain.id
  name    = format("_dmarc.%s", local.domain)
  type    = "TXT"
  content = "\"v=DMARC1; p=none\""
  ttl     = 1
  comment = "managed by terraform"
}

resource "aws_iam_user" "smtp" {
  name = "${local.prefix}-smtp"
}

# SES SMTP sends with SendRawEmail. In the sandbox SES also authorizes each
# recipient's identity, so the resource is every identity in the account and
# the condition limits who the mail can come from.
data "aws_iam_policy_document" "smtp" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = [format("arn:aws:ses:%s:%s:identity/*", data.aws_region.current.region, data.aws_caller_identity.current.account_id)]

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = [format("*@%s", local.domain)]
    }
  }
}

resource "aws_iam_user_policy" "smtp" {
  name   = "smtp"
  user   = aws_iam_user.smtp.name
  policy = data.aws_iam_policy_document.smtp.json
}
