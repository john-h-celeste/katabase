resource "google_compute_network" "main" {
  name                    = "rag-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name          = "rag-subnet"
  network       = google_compute_network.main.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/24"
}

resource "google_compute_firewall" "web" {
  name          = "allow-web"
  network       = google_compute_network.main.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["rag-web"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "allow-iap-ssh"
  network       = google_compute_network.main.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["rag-web"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}