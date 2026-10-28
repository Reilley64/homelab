# Ansible's nas_mounts role owns the CIFS mount units now. These blocks drop the
# old null_resource entries from state without touching the host.
removed {
  from = module.media

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.photos

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.roms

  lifecycle {
    destroy = false
  }
}
