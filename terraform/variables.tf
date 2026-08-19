variable "aws_region" {
  description = "AWS region to provision into. Must match the region your existing EC2/Minikube instance runs in, per project convention (see top-level README.md)."
  type        = string
}

variable "project_name" {
  description = "Short name used as a prefix for every resource this config creates, and as the EKS cluster name."
  type        = string
  default     = "item-manager-eks"
}

variable "k8s_namespace" {
  description = "Kubernetes namespace the app deploys into on EKS — matches helm/values-eks.yaml's namespace."
  type        = string
  default     = "item-manager"
}

variable "github_repository" {
  description = "GitHub \"owner/repo\" slug the deploy role's OIDC trust policy is scoped to. Must match this repo exactly."
  type        = string
  default     = "Stanleyobazee/stanley-item-manager"
}

variable "github_branch" {
  description = "Git branch the GitHub Actions OIDC trust policy is scoped to (only workflow_dispatch runs triggered from this branch can assume the deploy role). Defaults to \"eks\" since that's the branch this is actually built/tested on — change to \"main\" (and re-apply) once this work is merged."
  type        = string
  default     = "eks"
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes version. EKS only allows upgrading one minor version per apply — bump this by one (1.32, then 1.33, then 1.34) and re-apply between each step, waiting for the cluster to finish upgrading before the next bump. Currently mid-upgrade away from 1.31's extended-support window; target is 1.34+ per the AWS console's own recommendation."
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "EC2 instance type for the EKS managed node group. t3.medium chosen to leave headroom for kube-system (CNI, CoreDNS, CSI drivers) plus the app — see terraform/README.md's cost breakdown before changing."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count. Kept at 1 to minimize cost — this is a demo/learning cluster, not built for HA."
  type        = number
  default     = 1
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  description = "Max node count — 2 only to let managed node group rolling updates happen without downtime, not for scaling capacity."
  type        = number
  default     = 2
}

variable "postgres_password" {
  description = "Real Postgres password for EKS, stored in Secrets Manager. Set only in terraform.tfvars (gitignored, never committed) — never give this a default here. marked sensitive so it's redacted from CLI/plan output, though it still lands in terraform.tfstate — see README.md."
  type        = string
  sensitive   = true
}

variable "alertmanager_smtp_password" {
  description = "Gmail app password for Alertmanager email alerts, stored in Secrets Manager. Same handling as postgres_password — terraform.tfvars only, never a default."
  type        = string
  sensitive   = true
}
