#!/usr/bin/env python3
"""Create an access key for the SES SMTP user and print its SMTP credentials.

Prints the access key ID, which is the SMTP username, on the first line and
the SMTP password after it with no trailing newline. Pipe it straight into
`vault kv patch` so the password reaches neither a file nor Terraform state.

Usage: ses-smtp-credentials.py <iam user> [region]
"""

import base64
import hashlib
import hmac
import json
import subprocess
import sys


def smtp_password(secret_access_key: str, region: str) -> str:
    # https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html
    signature = ("AWS4" + secret_access_key).encode()
    for message in ("11111111", region, "ses", "aws4_request", "SendRawEmail"):
        signature = hmac.new(signature, message.encode(), hashlib.sha256).digest()
    return base64.b64encode(b"\x04" + signature).decode()


user = sys.argv[1]
region = sys.argv[2] if len(sys.argv) > 2 else "ap-southeast-2"
created = subprocess.run(
    ["aws", "iam", "create-access-key", "--user-name", user, "--output", "json"],
    check=True,
    capture_output=True,
    text=True,
)
key = json.loads(created.stdout)["AccessKey"]
sys.stdout.write(key["AccessKeyId"] + "\n" + smtp_password(key["SecretAccessKey"], region))
