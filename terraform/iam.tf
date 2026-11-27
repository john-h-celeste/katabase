# gives us special permissions

resource "google_service_account" "vm" { 
	account_id = "rag-vm" 
}

# ssh via IAP + os login
resource "google_project_iam_member" "iap" {
	for_each = toset(var.team_emails)
	project  = var.project_id
	role     = "roles/iap.tunnelResourceAccessor"
	member   = "user:${each.key}"
}

resource "google_project_iam_member" "oslogin" {
  for_each = toset(var.team_emails)
  project  = var.project_id
  role     = "roles/compute.osAdminLogin"
  member   = "user:${each.key}"
}