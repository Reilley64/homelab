module "media" {
  source = "./modules/mount"

  name        = "mnt-media"
  description = "Media"
  remote      = "//192.168.86.132/Media"
  target      = "/mnt/media"
  uid         = var.uid
  gid         = var.gid
  username    = var.username
  password    = var.password
}

module "photos" {
  source = "./modules/mount"

  name        = "mnt-photos"
  description = "Photos"
  remote      = "//192.168.86.132/Photos"
  target      = "/mnt/photos"
  uid         = var.uid
  gid         = var.gid
  username    = var.username
  password    = var.password
}

module "roms" {
  source = "./modules/mount"

  name        = "mnt-roms"
  description = "Roms"
  remote      = "//192.168.86.132/roms"
  target      = "/mnt/roms"
  uid         = var.uid
  gid         = var.gid
  username    = var.username
  password    = var.password
}
