terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }

    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.23"
    }

    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.6"
    }

    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
}
