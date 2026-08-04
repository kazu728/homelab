resource "cloudflare_r2_bucket" "piano_capture" {
  account_id = var.cloudflare_account_id
  name       = "piano-capture"
  location   = "apac"
}
