terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6"
    }
  }
}

locals {
  project = nonsensitive(var.vcluster.requirements["project"])
  region  = nonsensitive(var.vcluster.requirements["region"])
  zone    = nonsensitive(var.vcluster.requirements["zone"])

  vcluster_name      = nonsensitive(var.vcluster.instance.metadata.name)
  vcluster_namespace = nonsensitive(var.vcluster.instance.metadata.namespace)

  vpc_name            = "${local.vcluster_name}-vpc"
  public_subnet_cidr  = "10.10.2.0/24"
  public_subnet_name  = "${local.vcluster_name}-public"
  private_subnet_cidr = "10.10.1.0/24"
  private_subnet_name = "${local.vcluster_name}-private"

  nat_name        = "${local.vcluster_name}-nat"
  nat_router_name = "${local.vcluster_name}-router"
}

provider "google" {
  project = local.project
  region  = local.region
  zone    = local.zone
}


# Networking 
module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 11.1"

  project_id   = local.project
  network_name = local.vpc_name

  subnets = [
    {
      subnet_name           = local.public_subnet_name
      subnet_ip             = local.public_subnet_cidr
      subnet_region         = local.region
      subnet_private_access = "true"
    },
    {
      subnet_name           = local.private_subnet_name
      subnet_ip             = local.private_subnet_cidr
      subnet_region         = local.region
      subnet_private_access = "true"
    }
  ]

  firewall_rules = [
    # Allow SSH access via IAP (Identity-Aware Proxy)
    {
      name        = "allow-iap-ssh"
      description = "Allow SSH access via Identity-Aware Proxy"
      direction   = "INGRESS"
      ranges      = ["35.235.240.0/20"] # IAP source ranges
      target_tags = ["allow-iap-ssh"]
      allow = [{
        protocol = "tcp"
        ports    = ["22"]
      }]
      deny = []
    },
    # Allow HTTP/HTTPS traffic for public instances
    {
      name        = "allow-web-traffic"
      description = "Allow HTTP and HTTPS traffic"
      direction   = "INGRESS"
      ranges      = ["0.0.0.0/0"]
      allow = [{
        protocol = "tcp"
        ports    = ["80", "443"]
      }]
    },
    # Allow internal communication between subnets
    {
      name        = "allow-internal"
      description = "Allow internal communication within VPC"
      direction   = "INGRESS"
      ranges      = [local.public_subnet_cidr, local.private_subnet_cidr]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
          ports    = []
        }
      ]
    },
    # Allow health checks from Google Cloud Load Balancer
    {
      name        = "allow-health-check"
      description = "Allow health checks from Google Cloud Load Balancer"
      direction   = "INGRESS"
      priority    = 1000
      ranges      = ["130.211.0.0/22", "35.191.0.0/16"]
      allow = [{
        protocol = "tcp"
        ports    = ["80", "443", "8080"]
      }]
    }
  ]
}

# Cloud NAT for subnets
module "cloud_nat" {
  source  = "terraform-google-modules/cloud-nat/google"
  version = "~> 5.0"

  project_id                         = local.project
  region                             = local.region
  name                               = local.nat_name
  router                             = local.nat_router_name
  create_router                      = true
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  network                            = module.vpc.network_self_link
}
