# gives us special access

resource "google_service_account" "vm" {
  account_id   = "rag-vm"
  display_name = "RAG VM service account"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "iap_tunnel" {
  for_each = toset(var.team_emails)
  project  = var.project_id
  role     = "roles/iap.tunnelResourceAccessor"
  member   = "user:${each.key}"
}

resource "google_project_iam_member" "os_login" {
  for_each = toset(var.team_emails)
  project  = var.project_id
  role     = "roles/compute.osAdminLogin"
  member   = "user:${each.key}"
}

resource "google_project_iam_member" "compute_viewer" {
  for_each = toset(var.team_emails)
  project  = var.project_id
  role     = "roles/compute.viewer"
  member   = "user:${each.key}"
}