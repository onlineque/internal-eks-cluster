resource "helm_release" "kube-prometheus-stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "48.1.0"
  namespace  = "prometheus"
  values = [
    templatefile("${path.module}/helm/kube-prometheus-stack/templates/values.yaml.tmpl",
      {
        prometheus_route53_fqdn  = var.prometheus_route53_fqdn
        prometheus_internal_fqdn = var.prometheus_internal_fqdn
    })
  ]
}
