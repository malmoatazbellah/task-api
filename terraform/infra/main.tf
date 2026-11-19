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
              namespaces = ["task-api"]
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
# Helm provider — authenticates to EKS using the same AWS credentials
# =============================================================================
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

# =============================================================================
# kube-prometheus-stack — Prometheus + Grafana, trimmed for t3.small nodes
# =============================================================================
resource "helm_release" "kube_prometheus" {
  name             = "kube-prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "70.4.2"
  namespace        = "monitoring"
  create_namespace = true

  # Wait for all pods to be ready before Terraform considers this done
  wait    = true
  timeout = 600

  values = [<<-EOT
    alertmanager:
      enabled: false

    grafana:
      adminPassword: "capstone-admin"
      service:
        type: LoadBalancer
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          cpu: 200m
          memory: 256Mi
      sidecar:
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 50m
            memory: 64Mi
      dashboardProviders:
        dashboardproviders.yaml:
          apiVersion: 1
          providers:
            - name: default
              folder: ""
              type: file
              disableDeletion: false
              options:
                path: /var/lib/grafana/dashboards/default
      dashboards:
        default:
          task-api:
            json: |
              {
                "title": "Task API",
                "uid": "task-api",
                "schemaVersion": 38,
                "refresh": "30s",
                "panels": [
                  {
                    "id": 1,
                    "title": "Request Rate (req/s)",
                    "type": "timeseries",
                    "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
                    "targets": [{
                      "expr": "sum(rate(http_requests_total[1m])) by (method, route, status)",
                      "legendFormat": "{{method}} {{route}} {{status}}"
                    }]
                  },
                  {
                    "id": 2,
                    "title": "p95 Latency (s)",
                    "type": "timeseries",
                    "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
                    "targets": [{
                      "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, route))",
                      "legendFormat": "{{route}}"
                    }]
                  },
                  {
                    "id": 3,
                    "title": "Error Rate (%)",
                    "type": "stat",
                    "gridPos": { "x": 0, "y": 8, "w": 6, "h": 4 },
                    "targets": [{
                      "expr": "100 * sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))",
                      "legendFormat": "error %"
                    }]
                  }
                ]
              }

    prometheus:
      prometheusSpec:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 400m
            memory: 512Mi
        # Only scrape ServiceMonitors in the monitoring and task-api namespaces
        serviceMonitorNamespaceSelector:
          matchExpressions:
            - key: kubernetes.io/metadata.name
              operator: In
              values: ["monitoring", "task-api"]
        serviceMonitorSelector: {}
        retention: 6h
        retentionSize: "1GB"

    nodeExporter:
      enabled: false

    kubeStateMetrics:
      enabled: false

    prometheusOperator:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
  EOT
  ]

  depends_on = [module.eks]
}
