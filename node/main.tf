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
  project = var.vcluster.requirements["project"]
  region  = var.vcluster.requirements["region"]
  zone    = var.vcluster.requirements["zone"]

  vcluster_name      = var.vcluster.instance.metadata.name
  vcluster_namespace = var.vcluster.instance.metadata.namespace

  network_name = var.vcluster.nodeEnvironment.outputs["network_name"]
  subnet_name  = var.vcluster.nodeEnvironment.outputs["subnet_name"]

  instance_type = var.vcluster.requirements["instance-type"]
}

provider "google" {
  project = local.project
  region  = local.region
  zone    = local.zone
}

resource "random_id" "vm_suffix" {
  byte_length = 4
}

module "private_instance" {
  source  = "terraform-google-modules/vm/google//modules/compute_instance"
  version = "~> 13.0"

  region            = local.region
  zone              = local.zone
  subnetwork        = local.subnet_name
  num_instances     = 1
  hostname          = "${var.vcluster.name}-${random_id.vm_suffix.hex}"
  instance_template = module.instance_template.self_link

  # Will use NAT
  access_config = []

  labels = {
    vcluster  = local.vcluster_name
    namespace = local.vcluster_namespace
  }
}

data "google_project" "project" {
  project_id = local.project
}

data "google_compute_image" "img" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

module "instance_template" {
  source  = "terraform-google-modules/vm/google//modules/instance_template"
  version = "~> 13.0"

  region             = local.region
  project_id         = local.project
  network            = local.network_name
  subnetwork         = local.subnet_name
  subnetwork_project = local.project
  tags               = ["allow-iap-ssh"] # for IAP SSH access

  machine_type = local.instance_type

  source_image         = data.google_compute_image.img.self_link
  source_image_family  = data.google_compute_image.img.family
  source_image_project = data.google_compute_image.img.project

  disk_size_gb = 100
  disk_type    = "pd-standard"

  service_account = {
    # Use default compute service account
    email  = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data = var.vcluster.userData
  }

  startup_script = "#!/bin/bash\n# Ensure cloud-init runs\ncloud-init status --wait || true"
}
