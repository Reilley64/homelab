job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "batch"

  # The backup timer runs at 03:30 and refuses to run if these dumps are older
  # than a day.
  periodic {
    crons            = ["0 3 * * *"]
    time_zone        = "Australia/Melbourne"
    prohibit_overlap = true
  }

  group "${name}" {
    network {
      mode = "bridge"
    }

    volume "backups-postgres" {
      type   = "host"
      source = "backups-postgres"
    }

    task "${name}" {
      driver = "docker"

      config {
        image   = "${image}"
        command = "/bin/bash"
        args    = ["$${NOMAD_TASK_DIR}/dump.sh"]
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        PGUSER = "${database_user}"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          PGPASSWORD={{ .Data.data.password }}
          {{ end -}}
          {{ range service "postgres" }}PGHOST={{ .Address }}
          PGPORT={{ .Port }}{{ end }}
        EOT
      }

      # The same dumps the backup script made with docker exec: globals, then
      # one custom-format dump per database. They are written to the task
      # directory first, so a failed run leaves the previous dumps in place.
      template {
        destination = "local/dump.sh"
        data        = <<-EOT
          set -euo pipefail
          work="$NOMAD_TASK_DIR/dumps"
          mkdir -p "$work"
          pg_dumpall --globals-only >"$work/globals.sql"
          for db in $(psql -d postgres -Atc "select datname from pg_database where not datistemplate and datname <> 'postgres'"); do
            pg_dump -Fc "$db" >"$work/$db.dump"
          done
          rm -f /backups/*
          cp "$work"/* /backups/
        EOT
      }

      volume_mount {
        volume      = "backups-postgres"
        destination = "/backups"
      }

      resources {
        cpu        = 500
        memory     = 128
        memory_max = 1024
      }
    }
  }
}
