# output testing for debugging

output "lb_ip" {
  value       = google_compute_address.lb.address
}

output "url" {
  value = "http://${google_compute_address.lb.address}/"
}

output "ssh_command" {
  value       = "gcloud compute ssh ${google_compute_instance.rag.name} --zone ${var.zone} --tunnel-through-iap --project ${var.project_id}"
}

output "startup_log_command" {
  value       = "sudo tail -f /var/log/startup.log"
}