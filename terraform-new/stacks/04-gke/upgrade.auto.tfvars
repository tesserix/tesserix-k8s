# Keep this stack's reviewed version independent of shared application inputs.
control_plane_version = "1.37.0-gke.3503000"

# The regular production ceiling remains seven. Future upgrades replace a
# worker before adding its replacement, rather than exceeding that ceiling.
node_pool_upgrade_settings_overrides = {
  optimized-v2 = { max_surge = 0, max_unavailable = 1 }
}
