variable "tailscale_tailnet" {
  type        = string
  description = "Tailnet name or ID. Use '-' to default to the tailnet tied to the API key or OAuth client."
  default     = "-"
}
