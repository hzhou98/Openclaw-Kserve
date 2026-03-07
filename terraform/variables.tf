variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-west4"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-west4-a"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "openclaw-kserve"
}
