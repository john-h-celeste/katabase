output "lb_ip"   { 
	value = google_compute_address.lb.address 
}

output "ssh_cmd" { 
	value = "gcloud compute ssh rag-vm --tunnel-through-iap --zone ${var.zone}" 
}