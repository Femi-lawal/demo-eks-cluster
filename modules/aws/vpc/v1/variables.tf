variable "nat_gateway" {
  type        = bool
  default     = false
  description = "A boolean flag to deploy NAT Gateway."
}

variable "vpc_name" {
  type        = string
  nullable    = false
  description = "Name of the VPC."
}

variable "cidr_block" {
  type        = string
  default     = "10.0.0.0/16"
  description = "The IPv4 CIDR block for the VPC."

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "Must be a valid IPv4 CIDR block address."
  }
}

variable "enable_dns_support" {
  type        = bool
  default     = true
  description = "A boolean flag to enable/disable DNS support in the VPC."
}

variable "enable_dns_hostnames" {
  type        = bool
  default     = false
  description = "A boolean flag to enable/disable DNS hostnames in the VPC."
}

variable "default_tags" {
  type        = map(string)
  default     = {}
  description = "A map of tags to add to all resources."
}

variable "public_subnet_count" {
  type        = number
  default     = 3
  description = "Number of Public subnets."
}

variable "public_subnet_additional_bits" {
  type        = number
  default     = 4
  description = "Number of additional bits with which to extend the prefix."
}

variable "public_subnet_tags" {
  type        = map(string)
  default     = {}
  description = "A map of tags to add to all public subnets."
}

variable "private_subnet_count" {
  type        = number
  default     = 3
  description = "Number of Private subnets."
}

variable "private_subnet_additional_bits" {
  type        = number
  default     = 4
  description = "Number of additional bits with which to extend the prefix."
}

variable "private_subnet_tags" {
  type        = map(string)
  default     = {}
  description = "A map of tags to add to all private subnets."
}
