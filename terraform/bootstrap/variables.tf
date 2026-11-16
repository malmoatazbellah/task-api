variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Short project name used as a prefix for every resource (lowercase, no spaces)"
  type        = string
  default     = "capstone"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repo (e.g. 'jane-doe')"
  type        = string
}

variable "github_owner_id" {
  description = "Immutable numeric ID of the GitHub repository owner"
  type        = string
}

variable "github_repo_id" {
  description = "Immutable numeric ID of the GitHub repository"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (e.g. 'devops-capstone')"
  type        = string
}
