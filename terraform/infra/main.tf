locals {
  name = "${var.project}-${var.environment}" # e.g. capstone-dev
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Role created by the bootstrap stack; the app pipeline uses it to deploy.
data "aws_iam_role" "github_deploy" {
  name = "${var.project}-github-deploy"
}

# =============================================================================
# VPC — 2 AZs, public subnets (load balancers) + private subnets (worker nodes)
# =============================================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = local.name
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = [cidrsubnet(var.vpc_cidr, 8, 0), cidrsubnet(var.vpc_cidr, 8, 1)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 8, 10), cidrsubnet(var.vpc_cidr, 8, 11)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # cost saving for a course; use one per AZ in production
  enable_dns_hostnames = true

  # Tags that let Kubernetes find the right subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# =============================================================================
# ECR — container registry for the app image
# =============================================================================
resource "aws_ecr_repository" "app" {
  name                 = "${local.name}-task-api"
  image_tag_mutability = "IMMUTABLE" # a tag (git SHA) always points to the same image
  force_delete         = true        # course convenience for teardown

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 15 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}

# =============================================================================
# EKS — managed control plane + managed node group in private subnets
# =============================================================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  # Public API endpoint so GitHub-hosted runners and students can reach it.
  # Stretch goal: restrict with cluster_endpoint_public_access_cidrs.
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    metrics-server         = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 3
      desired_size   = var.node_desired_size
    }
  }

  # Whoever runs `terraform apply` (the pipeline role) becomes cluster admin.
  enable_cluster_creator_admin_permissions = true

  # EKS access entries: map IAM principals → Kubernetes permissions
  access_entries = merge(
    {
      github_deploy = {
        principal_arn = data.aws_iam_role.github_deploy.arn
        policy_associations = {
          admin = {
            # Stretch goal: scope this down to the app namespace with AmazonEKSEditPolicy
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      for idx, arn in var.admin_principal_arns : "admin_${idx}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    }
  )
}
