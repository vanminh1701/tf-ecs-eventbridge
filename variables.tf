variable "slack_webhook" {
  description = "Slack webhook url (included api token)"
  type        = string
  sensitive   = true
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}
