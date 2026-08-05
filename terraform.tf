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

    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.43"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
