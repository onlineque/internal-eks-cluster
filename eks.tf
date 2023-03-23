data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_availability_zones" "available" {}

locals {
  region   = var.aws_region
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = [ var.vpc_subnet1_id, var.vpc_subnet2_id ]
  private_subnets_cidr_blocks = [ var.csr1-cidr-block, var.csr2-cidr-block ]

  tags = var.tags
}

################################################################################
# Cluster
################################################################################

#tfsec:ignore:aws-eks-enable-control-plane-logging
module "eks" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.25.0"
  #source  = "terraform-aws-modules/eks/aws"
  #version = "~> 19.5"

  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true

  platform_teams    = var.platform_teams
  application_teams = var.application_teams

  vpc_id     = var.vpc_id
  private_subnet_ids = local.private_subnets

  managed_node_groups = var.managed_node_groups

  # Fargate profiles use the cluster primary security group so these are not utilized
  #create_cluster_security_group = false
  #create_node_security_group    = false

  # fargate profile turned on for any namespace starting with "fargate-"
  fargate_profiles = merge(
    { for i in range(2) :
      "app-wildcard-${element(split("-", local.azs[i]), 2)}" => {
        fargate_profile_name = "default-app-wildcard-${element(split("-", local.azs[i]), 2)}"
        fargate_profile_namespaces = [
          {
            namespace:  "fargate-*"
          }
        ]

        # We want to create a profile per AZ for high availability
        subnet_ids = [element(local.private_subnets, i)]
      }
    }
  )

  tags = local.tags
}

################################################################################
# Kubernetes Addons
################################################################################


module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/kubernetes-addons?ref=v4.25.0"

  eks_cluster_id       = module.eks.eks_cluster_id
  eks_cluster_endpoint = module.eks.eks_cluster_endpoint
  eks_oidc_provider    = module.eks.oidc_provider
  eks_cluster_version  = module.eks.eks_cluster_version

  # Wait on the `kube-system` profile before provisioning addons
  data_plane_wait_arn = join(",", [for prof in module.eks.fargate_profiles : prof.eks_fargate_profile_arn])

  # Enable Metrics server
  enable_metrics_server = true

  # Enable EFS CSI driver
  enable_aws_efs_csi_driver = true

  # Enable EBS CSI driver
  enable_amazon_eks_aws_ebs_csi_driver = true

  # Enable Cluster Autoscaler
  enable_cluster_autoscaler = true

  # Enable Prometheus
  enable_prometheus = true
  prometheus_helm_config = {
    set_values   = [
      {
         name  = "server.ingress.enabled"
         value = "true"
      },
      {
         name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/group\\.name"
         value = "prometheus"
      },
      {
         name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/listen-ports"
         value = "[{\"HTTP\": 80},{\"HTTPS\": 443}]"
      },
      {
         name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/subnets"
         value = "${var.vpc_subnet1_id}, ${var.vpc_subnet2_id}"
      },
      {
         name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn"
         value = "${aws_acm_certificate.wildcard_ssl_certificate.arn}"
      },
      {
         name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
         value = "internal"
      },
      {
         name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/ssl-redirect"
         value = "443"
      },
      {
         name  = "server.ingress.annotations.kubernetes\\.io/ingress\\.class"
         value = "alb"
      },
      {
         name  = "server.ingress.hosts[0]"
         value = "prometheus.${var.cluster_name}.private"
      },
      {
         name  = "server.ingress.hosts[1]"
         value = "prometheus-${var.cluster_name}.agcintranet.eu"
      },
      {
         name  = "server.ingress.tls[0].hosts[0]"
         value = "prometheus-${var.cluster_name}.agcintranet.eu"
      }
    ]
  }

  # Enable Gatekeeper
  enable_gatekeeper = true

  # Enable Velero
  enable_velero           = true
  velero_backup_s3_bucket = module.s3_bucket_velero.s3_bucket_id

  # Enable external-dns
  enable_external_dns            = true
  external_dns_private_zone      = true
  external_dns_route53_zone_arns = [module.zones.route53_zone_zone_arn["${var.cluster_name}.private"]]
  eks_cluster_domain             = "${var.cluster_name}.private"
  external_dns_helm_config       = {
    set_values   = [
      {
        name  = "policy"
        value = "sync"
      }
    ]
  }

  # Enable Fargate logging
  enable_fargate_fluentbit       = true
  fargate_fluentbit_addon_config = {
    flb_log_cw = true
  }

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller_helm_config = {
    set_values = [
      {
        name  = "vpcId"
        value = var.vpc_id
      },
      {
        name  = "podDisruptionBudget.maxUnavailable"
        value = 1
      },
    ]
  }


  tags = local.tags
  depends_on = [module.zones]
}

# TODO ?
#  private_subnet_tags = {
#    "kubernetes.io/role/internal-elb" = 1
#  }

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "~> 1.0"

  creation_token = var.cluster_name
  name           = var.cluster_name

  # Mount targets / security group
  mount_targets = {
    for k, v in zipmap(local.azs, local.private_subnets) : k => { subnet_id = v }
  }
  security_group_description = "${var.cluster_name} EFS security group"
  security_group_vpc_id      = var.vpc_id
  security_group_rules = {
    vpc = {
      # relying on the defaults provdied for EFS/NFS (2049/TCP + ingress)
      description = "NFS ingress from VPC private subnets"
      cidr_blocks = local.private_subnets_cidr_blocks
    }
  }

  tags = local.tags
}

resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs"
  }

  storage_provisioner = "efs.csi.aws.com"
  parameters = {
    provisioningMode = "efs-ap" # Dynamic provisioning
    fileSystemId     = module.efs.id
    directoryPerms   = "700"
  }

  mount_options = [
    "iam"
  ]

  depends_on = [
    module.eks
  ]
}

module "s3_bucket_velero" {
  source = "github.com/terraform-aws-modules/terraform-aws-s3-bucket?ref=v3.7.0"

  bucket = "s3s-i-velero-${var.cluster_name}"

  # S3 bucket-level Public Access Block configuration
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  acl = "private"

  # S3 Bucket Ownership Controls
  control_object_ownership = true
  object_ownership         = "BucketOwnerPreferred"

  versioning = {
    status     = true
    mfa_delete = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  #intelligent_tiering = {
  #    general = {
  #      status = "Enabled"
  #      filter = {
  #        prefix = "/"
  #      }
  #      tiering = {
  #        DEEP_ARCHIVE_ACCESS = {
  #          days = 0
  #        }
  #      }
  #    }
  #  }

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true

  tags = local.tags
}
