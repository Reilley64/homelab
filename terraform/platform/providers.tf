provider "aws" {
  region = "ap-southeast-2"
}

# The control plane providers read their address, token and CA from the
# environment (VAULT_*, CONSUL_HTTP_*, CONSUL_CACERT, NOMAD_*), so no token
# reaches a variable or the state.
provider "consul" {}

provider "nomad" {}

provider "vault" {}

# Reads CLOUDFLARE_API_TOKEN from the environment, the same token as the
# services root.
provider "cloudflare" {}
