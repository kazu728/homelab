provider "tailscale" {
  # Auth via env vars (e.g., TAILSCALE_API_KEY or OAuth client credentials).
  tailnet = var.tailscale_tailnet
}
