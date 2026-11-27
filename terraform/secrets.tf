resource "google_project_service" "secretmanager" {
	service = "secretmanager.googleapis.com"
}

resource "random_password" "db" {
	length  = 32
	special = false          # don't allow characters that can break .env or something else
}

resource "google_secret_manager_secret" "db" {
	secret_id = "postgres-password"
	replication { auto {} }
	depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "db" {
	secret      = google_secret_manager_secret.db.id
	secret_data = random_password.db.result
}

resource "google_service_account" "vm" {
	account_id = "rag-vm"
}

# account can read this one secret and nothing else
resource "google_secret_manager_secret_iam_member" "vm_reads_db" {
	secret_id = google_secret_manager_secret.db.id
	role      = "roles/secretmanager.secretAccessor"
	member    = "serviceAccount:${google_service_account.vm.email}"
}