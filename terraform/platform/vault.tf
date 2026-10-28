resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "Job secrets at kv/{namespace}/{job}"
}

resource "vault_audit" "file" {
  type = "file"
  path = "file"

  options = {
    file_path = "/var/log/vault/audit.log"
  }
}

# --- nomad workload identity ---

resource "vault_jwt_auth_backend" "nomad" {
  path               = "jwt-nomad"
  type               = "jwt"
  description        = "Nomad workload identities"
  jwks_url           = local.nomad_jwks_url
  jwks_ca_pem        = local.ca_cert
  jwt_supported_algs = ["RS256", "EdDSA"]
  default_role       = "nomad-workloads"
}

resource "vault_jwt_auth_backend_role" "nomad_workloads" {
  backend   = vault_jwt_auth_backend.nomad.path
  role_name = "nomad-workloads"
  role_type = "jwt"

  bound_audiences         = ["vault.io"]
  user_claim              = "/nomad_job_id"
  user_claim_json_pointer = true

  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }

  token_type     = "service"
  token_policies = [vault_policy.nomad_workloads.name]
  token_period   = 1800
  # Nomad renews the token for as long as the task runs.
  token_explicit_max_ttl = 0
}

# Each job reads only kv/{namespace}/{job}. The role copies both claims into
# the entity alias metadata, which the policy reads through the mount accessor.
resource "vault_policy" "nomad_workloads" {
  name = "nomad-workloads"

  policy = <<-EOT
    path "kv/data/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad.accessor}.metadata.nomad_namespace}}/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad.accessor}.metadata.nomad_job_id}}" {
      capabilities = ["read"]
    }
  EOT
}

# --- people ---

# The admin user is created by CLI in the runbook, because Vault needs a
# password to create a userpass user and the password must stay out of state.
resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = "userpass"
  description = "Admin login"
}

# Replaces the root token for day to day use and for Terraform.
resource "vault_policy" "admin" {
  name = "admin"

  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
  EOT
}
