output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
output "node_group_asg_tags" { value = module.eks.eks_managed_node_groups }
output "msk_bootstrap_sasl" { value = aws_msk_cluster.this.bootstrap_brokers_sasl_scram }