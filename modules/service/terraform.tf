terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.6.2"
    }

    caddy = {
      source  = "conradludgate/caddy"
      version = "0.2.8"
    }
  }
}
