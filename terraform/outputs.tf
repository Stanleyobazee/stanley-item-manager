output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.aws_region
}

output "kubeconfig_command" {
  description = "Run this to point kubectl/helm at the new cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "ecr_backend_url" {
  description = "Set as backend.image in helm/values-eks.yaml"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  description = "Set as frontend.image in helm/values-eks.yaml"
  value       = aws_ecr_repository.frontend.repository_url
}

output "postgres_secret_arn" {
  description = "Set as secretsManager.postgresSecretArn in helm/values-eks.yaml"
  value       = aws_secretsmanager_secret.postgres_password.arn
}

output "alertmanager_secret_arn" {
  description = "Set as the objectName in helm/monitoring/eks/secretprovider-alertmanager.yaml"
  value       = aws_secretsmanager_secret.alertmanager_smtp.arn
}

output "app_secrets_role_arn" {
  description = "Set as serviceAccount.roleArn in helm/values-eks.yaml (IRSA annotation)"
  value       = aws_iam_role.app_secrets.arn
}

output "alertmanager_secrets_role_arn" {
  description = "Set as alertmanager.serviceAccount.annotations in helm/monitoring/values-monitoring-eks.yaml (IRSA annotation)"
  value       = aws_iam_role.alertmanager_secrets.arn
}

output "github_actions_role_arn" {
  description = "Set as AWS_ROLE_ARN in .github/workflows/deploy-eks.yaml / repo variables — not a secret, just an ARN"
  value       = aws_iam_role.github_actions.arn
}
