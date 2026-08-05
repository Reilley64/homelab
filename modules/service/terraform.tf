terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.6.2"
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
