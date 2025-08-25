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
        "k8s.io/cluster-autoscaler/enabled"                       = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"           = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/nodegroup" = "default"
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

  role_name                        = "${var.cluster_name}-ca-irsa"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

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
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  wait       = true
  atomic     = true
  timeout    = 1200
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

############################
# Kafka MSK + Databricks
############################
# --- Security group for MSK brokers (allow Kafka from EKS nodes) ---
resource "aws_security_group" "msk_brokers" {
  name        = "${var.cluster_name}-msk-brokers"
  description = "MSK broker SG"
  vpc_id      = module.vpc.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SASL/SCRAM listens on 9096 (in-VPC). TLS-only would be 9094; IAM would be 9098. :contentReference[oaicite:0]{index=0}
resource "aws_security_group_rule" "msk_allow_eks_nodes" {
  type                     = "ingress"
  from_port                = 9096
  to_port                  = 9096
  protocol                 = "tcp"
  security_group_id        = aws_security_group.msk_brokers.id
  source_security_group_id = module.eks.node_security_group_id
}

resource "aws_kms_key" "msk_scram" {
  description             = "KMS CMK for MSK SCRAM secrets"
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # let the account (root) manage the key
      {
        Sid : "EnableIAMUserPermissions",
        Effect : "Allow",
        Principal : { AWS : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" },
        Action : "kms:*",
        Resource : "*"
      },
      # allow Secrets Manager to use the key to encrypt/decrypt secrets
      {
        Sid : "AllowSecretsManagerUse",
        Effect : "Allow",
        Principal : { Service : "secretsmanager.amazonaws.com" },
        Action : [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
        ],
        Resource : "*"
      }
    ]
  })
}

# --- SASL/SCRAM credentials in Secrets Manager (name must start with AmazonMSK_) --- :contentReference[oaicite:1]{index=1}
resource "aws_secretsmanager_secret" "scram_user" {
  name       = "AmazonMSK_${var.cluster_name}_scram_app"
  kms_key_id = aws_kms_key.msk_scram.arn # 👈 required for MSK
  # optional for labs so replacements aren’t blocked by 30-day recovery:
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "scram_user" {
  secret_id     = aws_secretsmanager_secret.scram_user.id
  secret_string = jsonencode({ username = "app", password = var.kafka_scram_password })
}

# --- MSK cluster ---
resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.cluster_name}-msk"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 3
  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk_brokers.id]
    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }
  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }
  client_authentication {
    sasl {
      scram = true
    }
  }
  enhanced_monitoring = "DEFAULT" # or "PER_BROKER" | "PER_TOPIC_PER_PARTITION"

  tags = { Project = var.cluster_name }
}

# Attach SCRAM secrets to the cluster
resource "aws_msk_scram_secret_association" "scram" {
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [aws_secretsmanager_secret.scram_user.arn]
}