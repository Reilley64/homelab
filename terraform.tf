terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.1"
    }

    caddy = {
      source  = "conradludgate/caddy"
      version = "0.2.8"
    }
  }
}
