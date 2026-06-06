resource "null_resource" "media" {
  provisioner "file" {
    content = templatefile("${path.module}/mnt-name.tpl", {
      description = var.description,
      source      = var.remote
      target      = var.target
      uid         = var.uid
      gid         = var.gid
    })

    destination = "/tmp/${var.name}.mount"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/${var.name}.mount /etc/systemd/system/",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now ${var.name}.mount",
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
