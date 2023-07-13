locals {
  monitoring_namespace = "prometheus"
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = local.monitoring_namespace
  }
}

resource "helm_release" "kube-prometheus-stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "48.1.0"
  namespace  = local.monitoring_namespace
  values = [
    templatefile("${path.module}/helm/kube-prometheus-stack/template/values.yaml.tmpl",
      {
        prometheus_route53_fqdn  = var.prometheus_route53_fqdn
        prometheus_internal_fqdn = var.prometheus_internal_fqdn
    })
  ]

  depends_on = [time_sleep.wait_for_eks_addons,kubernetes_namespace.monitoring]
}
