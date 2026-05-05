locals {
  enabled_services = toset([
    "tasks.googleapis.com",
    "sheets.googleapis.com",
  ])
}

resource "google_project_service" "shopping_automation" {
  for_each = local.enabled_services

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}
