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

data "aws_eks_cluster" "this" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# =============================================================================
# VPC — 2 AZs, public subnets (load balancers) + private subnets (worker nodes)
# =============================================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

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
            # Stretch goal: scope this down to the app namespace with AmazonEKSEditPolicy
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
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
# AWS Load Balancer Controller - IAM Policy
# =============================================================================

data "aws_iam_policy_document" "lbc" {

  # Allow creation of the ELB service-linked role
  statement {
    sid       = "CreateELBServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  # Discover VPC, subnet, security group, and ALB resources
  statement {
    sid = "DescribeResources"

    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:DescribeRouteTables",
      "ec2:GetSecurityGroupsForVpc",

      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags"
    ]

    resources = ["*"]
  }

  # Create security groups and manage ingress rules
  statement {
    sid = "ManageSecurityGroupIngress"

    actions = [
      "ec2:CreateSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress"
    ]

    resources = ["*"]
  }

  # Tag security groups during creation
  statement {
    sid     = "TagNewSecurityGroups"
    actions = ["ec2:CreateTags"]

    resources = [
      "arn:aws:ec2:*:*:security-group/*"
    ]

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

  # Manage tags on controller-owned security groups
  statement {
    sid = "ManageSecurityGroupTags"

    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags"
    ]

    resources = [
      "arn:aws:ec2:*:*:security-group/*"
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

  # Modify and delete controller-owned security groups
  statement {
    sid = "ManageOwnedSecurityGroups"

    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup"
    ]

    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  # Create ALBs and target groups with controller ownership tags
  statement {
    sid = "CreateLoadBalancersAndTargetGroups"

    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup"
    ]

    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  # Create and delete listeners and routing rules
  statement {
    sid = "ManageListenersAndRules"

    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule"
    ]

    resources = ["*"]
  }

  # Tag ALBs and target groups during creation
  statement {
    sid = "TagNewLoadBalancersAndTargetGroups"

    actions = [
      "elasticloadbalancing:AddTags"
    ]

    resources = [
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values = [
        "CreateLoadBalancer",
        "CreateTargetGroup"
      ]
    }

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  # Manage tags on controller-owned ALBs and target groups
  statement {
    sid = "ManageLoadBalancerAndTargetGroupTags"

    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags"
    ]

    resources = [
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
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

  # Manage tags on listeners and listener rules
  statement {
    sid = "ManageListenerTags"

    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags"
    ]

    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
    ]
  }

  # Modify and delete controller-owned ALBs and target groups
  statement {
    sid = "ManageOwnedLoadBalancersAndTargetGroups"

    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup"
    ]

    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  # Register and deregister application pod IPs
  statement {
    sid = "ManageTargetRegistration"

    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets"
    ]

    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
    ]
  }

  # Modify HTTP listeners and routing rules
  statement {
    sid = "ModifyListenersAndRules"

    actions = [
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyListenerAttributes",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetRulePriorities"
    ]

    resources = ["*"]
  }
}

# =============================================================================
# AWS Load Balancer Controller - IAM Managed Policy
# =============================================================================

resource "aws_iam_policy" "lbc" {
  name        = "${local.name}-aws-lbc"
  description = "IAM permissions for AWS Load Balancer Controller"
  policy      = data.aws_iam_policy_document.lbc.json
}


# =============================================================================
# AWS Load Balancer Controller - IAM Role and Pod Identity
# =============================================================================

# Trust policy for EKS Pod Identity
data "aws_iam_policy_document" "lbc_trust" {
  statement {
    sid     = "AllowEksPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["aws-load-balancer-controller"]
    }
  }
}

# IAM role assumed by the AWS Load Balancer Controller
resource "aws_iam_role" "lbc" {
  name               = "${local.name}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_trust.json
}

# Attach the controller permissions policy to its role
resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# Associate the IAM role with the controller's Kubernetes service account
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    }
  ]

  depends_on = [
    aws_eks_pod_identity_association.lbc
  ]
}
