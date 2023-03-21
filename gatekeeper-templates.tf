data "template_file" "gatekeeper-templates" {
  template = file("${path.module}/helm/gatekeeper-templates/template/values.yaml.tmpl")
  vars = {
    limits_cpu      = var.pod_cpu_limit
    limits_memory   = var.pod_memory_limit
    requests_cpu    = var.pod_cpu_requests
    requests_memory = var.pod_memory_requests
  }
}

resource "helm_release" "gatekeeper-templates" {
  name      = "gatekeeper-templates"
  chart     = "${path.module}/helm/gatekeeper-templates/chart/"
  version   = "1.0.0"
  namespace = "gatekeeper-system"
  values    = [data.template_file.gatekeeper-templates.rendered]
}
