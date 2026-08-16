variable "name" {
  description = "Network name. Must be unique within the project."
  type        = string

  validation {
    condition     = length(var.name) > 2 && length(var.name) <= 40
    error_message = "name must be between 3 and 40 characters."
  }
}

variable "cidr_block" {
  description = "CIDR block for the network."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid CIDR, for example 10.0.0.0/16."
  }
}

variable "subnet_count" {
  description = "Number of subnets to carve out of cidr_block."
  type        = number
  default     = 2

  validation {
    condition     = var.subnet_count >= 1 && var.subnet_count <= 16
    error_message = "subnet_count must be between 1 and 16."
  }
}

variable "common_labels" {
  description = "Labels recorded against the network."
  type        = map(string)
  default     = {}
}
