resource "aws_eks_addon" "amazon_cloudwatch_observability" {
  cluster_name                = var.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"

  configuration_values = jsonencode({
    resources = {
      limits = {
        cpu    = "256m"
        memory = "150Mi"
      }
      requests = {
        cpu    = "256m"
        memory = "150Mi"
      }
    }
  })
}
