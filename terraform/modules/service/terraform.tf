terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.5.0"
    }

    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.6"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }

    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.55"
    }
  }
}
