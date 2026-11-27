variable "project_id"   { type = string }
variable "region"       { type = string  default = "us-east1" }
variable "zone"         { type = string  default = "us-east1-b" }
variable "machine_type" { type = string  default = "e2-standard-4" }
variable "repo_url"     { type = string }
variable "team_emails"  { type = list(string) }