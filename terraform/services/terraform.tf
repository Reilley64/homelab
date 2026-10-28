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

    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.23"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }

    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.43"
    }

    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.55"
    }
  }
}
