resource "null_resource" "media" {
  triggers = {
    unit_file = templatefile(format("%s/mnt-name.tftpl", path.module), {
      description = var.description,
      source      = var.remote
      target      = var.target
      uid         = var.uid
      gid         = var.gid
    })
  }

  provisioner "file" {
    content = templatefile(format("%s/mnt-name.tftpl", path.module), {
      description = var.description,
      source      = var.remote
      target      = var.target
      uid         = var.uid
      gid         = var.gid
    })

    destination = format("/tmp/%s.mount", var.name)
  }

  provisioner "remote-exec" {
    inline = [
      format("sudo mv /tmp/%s.mount /etc/systemd/system/", var.name),
      "sudo systemctl daemon-reload",
      format("sudo systemctl enable --now %s.mount", var.name),
      format("sudo systemctl restart %s.mount", var.name),
    ]
  }

  connection {
    type     = "ssh"
    host     = "192.168.86.199"
    user     = var.username
    password = var.password
    timeout  = "30s"
  }
}
