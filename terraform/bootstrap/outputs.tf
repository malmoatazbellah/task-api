# Copy these values into GitHub → Settings → Secrets and variables → Actions → Variables

output "TF_STATE_BUCKET" {
  value = aws_s3_bucket.tf_state.bucket
}

output "AWS_TERRAFORM_ROLE_ARN" {
  value = aws_iam_role.github_terraform.arn
}

output "AWS_DEPLOY_ROLE_ARN" {
  value = aws_iam_role.github_deploy.arn
}

output "AWS_REGION" {
  value = var.aws_region
}

output "AWS_PLAN_ROLE_ARN" {
  value = aws_iam_role.github_plan.arn
}
