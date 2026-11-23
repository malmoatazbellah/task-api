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

data "aws_iam_role" "github_terraform" {
  name = "${var.project}-github-terraform"
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
    coredns    = {}
    kube-proxy = {}
    metrics-server = {
      configuration_values = jsonencode({
        containerPort = 4443
      })
    }
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
  enable_cluster_creator_admin_permissions = false

  kms_key_administrators = [data.aws_iam_role.github_terraform.arn]

  # EKS access entries: map IAM principals → Kubernetes permissions
  access_entries = merge(
    {
      github_deploy = {
        principal_arn = data.aws_iam_role.github_deploy.arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = ["task-api", "task-api-staging"]
            }
          }
        }
      }

      cluster_creator = {
        principal_arn = data.aws_iam_role.github_terraform.arn
        policy_associations = {
          admin = {
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

# =============================================================================
# AWS Load Balancer Controller — IAM role via EKS Pod Identity
# =============================================================================
data "aws_iam_policy_document" "lbc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lbc" {
  statement {
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }
  statement {
    actions = [
      "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses", "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways", "ec2:DescribeVpcs", "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces", "ec2:DescribeTags", "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools", "ec2:GetSecurityGroupsForVpc",
      "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies", "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTrustStores", "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeCapacityReservation",
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "cognito-idp:DescribeUserPoolClient", "acm:ListCertificates", "acm:DescribeCertificate",
      "iam:ListServerCertificates", "iam:GetServerCertificate",
      "waf-regional:GetWebACL", "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL", "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL", "wafv2:GetWebACLForResource", "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL",
      "shield:GetSubscriptionState", "shield:DescribeProtection",
      "shield:CreateProtection", "shield:DeleteProtection",
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:DeleteSecurityGroup"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions = [
      "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule",
    ]
    resources = ["*"]
  }
  statement {
    actions = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }
  statement {
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListenerAttributes", "elasticloadbalancing:ModifyCapacityReservation",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions = ["elasticloadbalancing:AddTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values   = ["CreateTargetGroup", "CreateLoadBalancer"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }
  statement {
    actions   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }
  statement {
    actions = [
      "elasticloadbalancing:SetWebAcl", "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates", "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${local.name}-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
}

resource "aws_iam_policy" "lbc" {
  name   = "${local.name}-lbc"
  policy = data.aws_iam_policy_document.lbc.json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}