terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# required. disable_on_destroy = false so `terraform destroy` does not switch the APIs off for the whole project.
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "iap.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.key
  disable_on_destroy = false
}

resource "google_compute_address" "lb" {
  name       = "rag-lb-ip"
  depends_on = [google_project_service.apis]
}

resource "google_compute_disk" "data" {
  name       = "rag-data"
  type       = "pd-balanced"
  size       = var.data_disk_gb
  depends_on = [google_project_service.apis]
}

resource "google_compute_instance" "rag" {
  name         = "rag-vm"
  machine_type = var.machine_type
  tags         = ["rag-web"] # the firewall rules target this tag

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "data-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      nat_ip = google_compute_address.lb.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
    repo-url       = var.repo_url
    repo-branch    = var.repo_branch
  }

  metadata_startup_script = file("${path.module}/../scripts/bootstrap.sh")

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.db,
    google_secret_manager_secret_iam_member.vm_reads_db,
  ]
}