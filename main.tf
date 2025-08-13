data "aws_caller_identity" "current" {}

############################
# VPC
############################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    "Project" = var.cluster_name
  }
}

############################
# EKS cluster
############################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = var.cluster_name
  cluster_version                = "1.32"
  enable_irsa                    = true
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # One simple managed node group
  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min
      desired_size   = var.node_desired
      max_size       = var.node_max
      ami_type       = "AL2_x86_64"
      capacity_type  = "ON_DEMAND"

      # Required for Cluster Autoscaler auto-discovery
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                         = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"             = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/nodegroup"   = "default"
      }
    }
  }

  tags = {
    "Project" = var.cluster_name
  }
}

############################
# IRSA role for Cluster Autoscaler
############################
module "iam_irsa_ca" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-ca-irsa"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names   = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  tags = {
    "Project" = var.cluster_name
  }
}

############################
# metrics-server (required for HPA)
############################
resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  namespace        = "kube-system"
  wait             = true
  atomic           = true
  timeout          = 1200
  values = [<<-YAML
    args:
      - --kubelet-insecure-tls
      - --kubelet-preferred-address-types=InternalIP,Hostname
  YAML
  ]
  depends_on = [module.eks, time_sleep.wait_for_access]
}

############################
# Cluster Autoscaler (auto-discovers our node group)
############################
resource "helm_release" "cluster_autoscaler" {
  name             = "cluster-autoscaler"
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  namespace        = "kube-system"
  create_namespace = false

  # Minimal values; tune as you learn
  values = [<<-YAML
    autoDiscovery:
      clusterName: "${var.cluster_name}"
    awsRegion: "${var.region}"
    rbac:
      serviceAccount:
        create: true
        name: cluster-autoscaler
        annotations:
          eks.amazonaws.com/role-arn: "${module.iam_irsa_ca.iam_role_arn}"
    extraArgs:
      balance-similar-node-groups: "true"
      skip-nodes-with-system-pods: "false"
      stderrthreshold: info
      v: "4"
  YAML
  ]
  depends_on = [module.eks, module.iam_irsa_ca, time_sleep.wait_for_access]
}

# Give that principal access to the cluster
resource "aws_eks_access_entry" "current" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

# Attach admin policy at cluster scope
resource "aws_eks_access_policy_association" "current_admin" {
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = data.aws_caller_identity.current.arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.current]
}

resource "time_sleep" "wait_for_access" {
  depends_on      = [module.eks, aws_eks_access_policy_association.current_admin]
  create_duration = "30s"
}
