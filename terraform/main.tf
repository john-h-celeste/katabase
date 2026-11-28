terraform {
	required_providers {
		google = { source = "hashicorp/google" }
		random = { source = "hashicorp/random" }
	}
}

provider "google" {
	project = var.project_id
	region  = var.region
	zone    = var.zone
}

resource "google_project_service" "apis" {
	for_each = toset(["compute.googleapis.com", "secretmanager.googleapis.com", "iap.googleapis.com", "monitoring.googleapis.com"])
	service = each.key
}

resource "google_compute_address" "lb" {
	name = "rag-lb-ip"
}

resource "google_compute_disk" "data" {
	name = "rag-data"
	type = "pd-balanced"
	size = 40
}

resource "google_compute_instance" "rag" {
	name         = "rag-vm"
	machine_type = var.machine_type
	tags         = ["rag-web"]

	boot_disk {
		initialize_params { image = "ubuntu-os-cloud/ubuntu-2204-lts" }
	}

	attached_disk {
		source      = google_compute_disk.data.id
		device_name = "data-disk"      # this should(?) become /dev/disk/by-id/google-data-disk
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

	metadata_startup_script = file("${path.module}/../scripts/startup.sh")
	depends_on = [google_project_service.apis]
}