# ── GitHub OIDC ───────────────────────────────────────────────────────────────
# No static AWS_ACCESS_KEY_ID/SECRET stored in GitHub anywhere — CI exchanges a short-lived
# GitHub-issued OIDC token for temporary AWS credentials that expire when the job ends.
# See ../SECRETS.md for the full explanation of how this works.

data "aws_caller_identity" "current" {}

# GitHub's OIDC provider URL is a per-AWS-ACCOUNT singleton, not per-project — if any other
# Terraform config (or a manual setup) in this account already registered
# token.actions.githubusercontent.com, IAM will reject a second `resource` for the same URL
# with "EntityAlreadyExists". Referenced here as a data source instead of a resource this
# project owns, specifically so `terraform destroy` in this repo can never delete a provider
# some other project might still depend on. If your account doesn't have one yet, this data
# lookup will fail instead — see SECRETS.md's "GitHub OIDC" section for the one-time
# `aws iam create-open-id-connect-provider` command to create it by hand first.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # GitHub's OIDC `sub` claim now embeds immutable numeric owner/repo IDs alongside the
  # names — e.g. "repo:Stanleyobazee@138321682/stanley-item-manager@1311034129:ref:refs/
  # heads/eks", not the classic "repo:OWNER/REPO:ref:..." this was originally built
  # against. Confirmed via CloudTrail (aws cloudtrail lookup-events --lookup-attributes
  # AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity) after every other
  # part of this trust policy checked out but AssumeRoleWithWebIdentity still failed —
  # the `Username`/`principalId` field on the failed event shows exactly what GitHub
  # actually sent. Wildcarding the numeric ID with `@*` (StringLike, not StringEquals)
  # instead of hardcoding the literal numbers keeps this working if IDs are ever
  # unavailable to read at plan time, while still requiring the real owner/repo names.
  github_repo_parts = split("/", var.github_repository)
}

data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    # Scoped to this exact repo + branch — a workflow run from a fork or a different
    # branch cannot assume this role, even with a valid GitHub-issued OIDC token.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo_parts[0]}@*/${local.github_repo_parts[1]}@*:ref:refs/heads/${var.github_branch}"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json
}

# Cluster-admin scope (AmazonEKSClusterAdminPolicy, cluster-wide) — broader than
# least-privilege on purpose, so CI can also manage cluster-wide resources (e.g. installing
# the Secrets Store CSI driver) without needing further RBAC changes later. See
# README.md's "GitHub Actions RBAC scope" section for the tradeoff this represents.
data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # AWS requires this specific action to be account-wide — cannot be resource-scoped
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.backend.arn, aws_ecr_repository.frontend.arn]
  }

  statement {
    sid       = "DescribeCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }

  statement {
    sid       = "ReadAppSecretsRole"
    effect    = "Allow"
    actions   = ["iam:GetRole"]
    resources = [aws_iam_role.app_secrets.arn]
  }

  statement {
    sid    = "ManageAppSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue",
    ]
    resources = [aws_secretsmanager_secret.postgres_password.arn, aws_secretsmanager_secret.alertmanager_smtp.arn]
  }

  statement {
    sid       = "DecryptWithProjectKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.secrets.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_permissions" {
  name   = "${var.project_name}-github-actions-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}

# ── VPC ──────────────────────────────────────────────────────────────────────
# Private subnets for nodes + a single NAT Gateway for outbound (ECR pulls, AWS API calls).
# One NAT instead of one-per-AZ halves the NAT cost for this single-environment cluster —
# adds ~$33/month vs. the public-subnet-only alternative. See README.md's cost table.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.60.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.60.1.0/24", "10.60.2.0/24"]
  public_subnets  = ["10.60.101.0/24", "10.60.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ── EKS Node IAM Role ────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── EKS ──────────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.project_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  # Without this, NOBODY has kubectl access to the cluster by default in this module —
  # unlike the raw AWS EKS API (which auto-grants the creating principal admin access),
  # terraform-aws-modules/eks/aws opts out of that unless told otherwise. This grants
  # whichever IAM identity runs `terraform apply` an automatic cluster-admin access entry.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Using the explicitly defined node role above instead of letting the module create one —
  # keeps every IAM role in this config visible in one place.
  create_node_iam_role = false

  # Applied to every resource this module creates (cluster, node group, security groups,
  # etc.) — shows up in AWS Console resource lists/cost explorer filters, not just on the
  # worker node EC2 instances specifically (see the node-group-level `tags` below for that).
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }

  eks_managed_node_groups = {
    default = {
      instance_types  = [var.node_instance_type]
      min_size        = var.node_min_size
      max_size        = var.node_max_size
      desired_size    = var.node_desired_size
      iam_role_arn    = aws_iam_role.eks_node.arn
      create_iam_role = false

      # Kubernetes-side identification (kubectl get nodes --show-labels, node selectors).
      labels = {
        role = "general"
      }

      # AWS-side identification — lands on the node group's ASG with propagate_at_launch,
      # so the actual EC2 instances get these tags too (visible in the EC2 Console, cost
      # explorer, and `aws ec2 describe-instances --filters "Name=tag:Project,..."`).
      tags = {
        Name      = "${var.project_name}-worker-node"
        Project   = var.project_name
        Role      = "eks-worker"
        ManagedBy = "terraform"
      }
    }
  }

  cluster_addons = {
    vpc-cni    = { most_recent = true }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  # Modern access-entry API (not the legacy aws-auth ConfigMap). Cluster-admin, matching
  # the CI role's IAM permissions above — see README.md for the least-privilege alternative
  # this deliberately isn't using.
  access_entries = {
    github_actions = {
      principal_arn = aws_iam_role.github_actions.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

# ── ECR ──────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lets `terraform destroy` remove this even if it has images pushed to it

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

locals {
  ecr_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy     = local.ecr_lifecycle_policy
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name
  policy     = local.ecr_lifecycle_policy
}

# ── KMS key for Secrets Manager encryption ───────────────────────────────────

resource "aws_kms_key" "secrets" {
  description             = "${var.project_name} — encrypts app secrets in Secrets Manager"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── AWS Secrets Manager ──────────────────────────────────────────────────────
# Real values come from terraform.tfvars (gitignored, never committed) via
# var.postgres_password / var.alertmanager_smtp_password, both marked sensitive.
#
# IMPORTANT — unlike Phases A-C's original design, these values DO end up in
# terraform.tfstate (in the S3 backend) once applied. `sensitive = true` only redacts them
# from CLI output/logs, not from state contents. See README.md's "State file now contains
# real secrets" section for what this means for protecting the state bucket.

resource "aws_secretsmanager_secret" "postgres_password" {
  name                    = "${var.project_name}/postgres-password"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0 # immediate delete on `terraform destroy` — this is a session-based demo
  # cluster's secret, not a production credential worth a 7-30 day accidental-deletion safety
  # net. Without this, a destroyed-then-recreated secret with the same name fails to create
  # ("still scheduled for deletion") until that window elapses.
}

resource "aws_secretsmanager_secret_version" "postgres_password" {
  secret_id     = aws_secretsmanager_secret.postgres_password.id
  secret_string = var.postgres_password
}

resource "aws_secretsmanager_secret" "alertmanager_smtp" {
  name                    = "${var.project_name}/alertmanager-smtp-password"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0 # see postgres_password above for why
}

resource "aws_secretsmanager_secret_version" "alertmanager_smtp" {
  secret_id     = aws_secretsmanager_secret.alertmanager_smtp.id
  secret_string = var.alertmanager_smtp_password
}

# ── IRSA: app secrets (Secrets Store CSI Driver) ──────────────────────────────
# The Secrets Store CSI Driver's AWS provider authenticates as the MOUNTING POD's own
# ServiceAccount via IRSA when it fetches secrets at volume-mount time — so this role's
# trust policy is scoped to the app's ServiceAccount (helm/templates/serviceaccount.yaml),
# not to the CSI driver daemonset's own ServiceAccount.

locals {
  oidc_provider = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

data "aws_iam_policy_document" "app_secrets_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:${var.k8s_namespace}-eks-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_secrets" {
  name               = "${var.project_name}-app-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.app_secrets_assume.json
}

data "aws_iam_policy_document" "app_secrets_access" {
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.postgres_password.arn, aws_secretsmanager_secret.alertmanager_smtp.arn]
  }
  statement {
    sid       = "DecryptWithProjectKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.secrets.arn]
  }
}

resource "aws_iam_role_policy" "app_secrets_access" {
  name   = "${var.project_name}-app-secrets-access"
  role   = aws_iam_role.app_secrets.id
  policy = data.aws_iam_policy_document.app_secrets_access.json
}

# ── IRSA: Alertmanager secrets (monitoring namespace) ─────────────────────────
# Alertmanager (from kube-prometheus-stack) runs as its own pod in the `monitoring`
# namespace under its own ServiceAccount — separate from the app's ServiceAccount above,
# so it needs its own IRSA role rather than reusing app_secrets. The ServiceAccount name is
# set explicitly via helm/monitoring/values-monitoring-eks.yaml's
# alertmanager.serviceAccount.name, not left to the chart's auto-generated default — same
# reasoning as always naming things explicitly rather than guessing chart-generated names
# (see helm/monitoring/README.md's naming history for why that specifically matters here).

data "aws_iam_policy_document" "alertmanager_secrets_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:monitoring:monitoring-alertmanager-eks-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alertmanager_secrets" {
  name               = "${var.project_name}-alertmanager-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.alertmanager_secrets_assume.json
}

data "aws_iam_policy_document" "alertmanager_secrets_access" {
  statement {
    sid       = "ReadAlertmanagerSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.alertmanager_smtp.arn] # not the postgres secret — least privilege
  }
  statement {
    sid       = "DecryptWithProjectKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.secrets.arn]
  }
}

resource "aws_iam_role_policy" "alertmanager_secrets_access" {
  name   = "${var.project_name}-alertmanager-secrets-access"
  role   = aws_iam_role.alertmanager_secrets.id
  policy = data.aws_iam_policy_document.alertmanager_secrets_access.json
}

# ── IRSA: EBS CSI Driver ───────────────────────────────────────────────────────

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
