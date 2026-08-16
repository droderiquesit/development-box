variable "project_name" {
  description = "Project name used as a prefix for every generated resource."
  type        = string
  default     = "devbox-example"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 3-31 characters, starting with a letter."
  }
}

variable "environments" {
  description = "Environments to generate, keyed by environment name."
  type = map(object({
    region     = string
    replicas   = number
    cidr_block = string
  }))

  default = {
    dev = {
      region     = "us-east-1"
      replicas   = 1
      cidr_block = "10.10.0.0/16"
    }
    prod = {
      region     = "us-east-1"
      replicas   = 3
      cidr_block = "10.20.0.0/16"
    }
  }

  validation {
    condition     = alltrue([for e in var.environments : e.replicas >= 1 && e.replicas <= 10])
    error_message = "replicas must be between 1 and 10 for every environment."
  }

  validation {
    condition     = alltrue([for e in var.environments : can(cidrhost(e.cidr_block, 0))])
    error_message = "cidr_block must be a valid CIDR for every environment."
  }
}

variable "common_labels" {
  description = "Labels applied to every resource. Consistent labelling is what makes cost and ownership attributable later."
  type        = map(string)
  default = {
    managed_by = "terraform"
    example    = "devbox"
  }
}
