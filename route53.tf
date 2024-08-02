module "zones" {
  source  = "github.com/terraform-aws-modules/terraform-aws-route53//modules/zones?ref=v2.10.2"

  zones = {
    "${var.cluster_name}.private" = {
      comment = "${var.cluster_name} DNS zone for external-dns"
      vpc     = [
        {
          vpc_id = var.vpc_id
        }
      ],
      tags    = local.tags
    }
    
    "${var.cluster_name}.${var.private_zone_suffix}" = {
      comment = "${var.cluster_name} DNS zone (new naming) for external-dns"
      vpc     = [
        {
          vpc_id = var.vpc_id
        }
      ],
      tags    = local.tags
    }
  }
}

resource "aws_route53_vpc_association_authorization" "route53_association_authorization" {
  count   = length(module.zones.route53_zone_zone_id)
  vpc_id  = var.transit_vpc_id
  zone_id = values(module.zones.route53_zone_zone_id)[count.index]
}
