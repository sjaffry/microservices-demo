terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0.0"
    }
  }
}

provider "google" {
  project = "gcp-onboarding-project-480819"
  region  = "us-west1"
}

provider "google-beta" {
  project = "gcp-onboarding-project-480819"
  region  = "us-west1"
}

resource "google_compute_network" "app-network" {
  provider                = google-beta
  name                    = "app-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "app-subnetwork" {
  provider      = google-beta
  name          = "app-subnetwork-1"
  ip_cidr_range = "192.168.0.0/16"
  region        = "us-west1"
  network       = google_compute_network.app-network.id
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pod-ranges"
    ip_cidr_range = "10.0.0.0/16"
  }
}

resource "google_compute_network" "control-network" {
  provider                = google-beta
  name                    = "control-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "control-subnetwork" {
  provider      = google-beta
  name          = "control-subnetwork-1"
  ip_cidr_range = "172.16.0.0/16"
  region        = "us-west1"
  network       = google_compute_network.control-network.id
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "control-pod-ranges"
    ip_cidr_range = "10.1.0.0/16"
  }
}

resource "google_container_cluster" "default" {
  provider = google-beta
  name     = "multi-vpc-cluster"
  location = "us-west1"

  deletion_protection = false

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.app-network.id
  subnetwork = google_compute_subnetwork.app-subnetwork.id

  min_master_version = "1.33.5-gke.1308000"

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name = "pod-ranges"
  }

  workload_identity_config {
    workload_pool = "gcp-onboarding-project-480819.svc.id.goog"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "STORAGE", "POD", "DEPLOYMENT", "STATEFULSET", "DAEMONSET", "HPA", "JOBSET", "CADVISOR", "KUBELET", "DCGM"]
    managed_prometheus {
      enabled = true
    }
  }

  dns_config {
    cluster_dns       = "CLOUD_DNS"
    cluster_dns_scope = "CLUSTER_SCOPE"
  }

  default_max_pods_per_node = 64

  security_posture_config {
    mode               = "DISABLED"
    vulnerability_mode = "VULNERABILITY_DISABLED"
  }

  datapath_provider       = "ADVANCED_DATAPATH"
  enable_multi_networking = true

  master_authorized_networks_config {}

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  binary_authorization {
    evaluation_mode = "DISABLED"
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  node_config {
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

}

resource "google_container_node_pool" "default" {
  provider = google-beta
  name     = "default-pool"
  cluster  = google_container_cluster.default.id
  location = "us-west1"
  max_pods_per_node = 64

  initial_node_count = 3

  autoscaling {
    min_node_count  = 0
    max_node_count  = 3
    location_policy = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = "e2-medium"
    image_type   = "COS_CONTAINERD"
    disk_type    = "pd-balanced"
    disk_size_gb = 100

    workload_metadata_config {
      mode = "GKE_METADATA"
    }


    metadata = {
      disable-legacy-endpoints = "true"
    }

    tags = ["gke-standard"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append"
    ]
  }

  network_config {
    pod_range = google_compute_subnetwork.app-subnetwork.secondary_ip_range[0].range_name
    additional_node_network_configs {
      network    = google_compute_network.control-network.name
      subnetwork = google_compute_subnetwork.control-subnetwork.name
    }
    additional_pod_network_configs {
      subnetwork          = google_compute_subnetwork.control-subnetwork.name
      secondary_pod_range = "control-pod-ranges"
      max_pods_per_node   = 64
    }
  }
}

resource "google_service_account" "microservices_app_sa" {
  provider     = google-beta
  project      = "gcp-onboarding-project-480819"
  account_id   = "microservices-app-sa"
  display_name = "Microservices App Service Account"
}

locals {
  web_store_ksas = toset([
    "currencyservice",
    "loadgenerator",
    "productcatalogservice",
    "checkoutservice",
    "shippingservice",
    "cartservice",
    "emailservice",
    "paymentservice",
    "frontend",
    "recommendationservice",
    "adservice",
  ])
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  provider = google-beta
  for_each = local.web_store_ksas

  service_account_id = google_service_account.microservices_app_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:gcp-onboarding-project-480819.svc.id.goog[web-store/${each.key}]"
}

resource "google_project_iam_member" "gsa_monitoring_permissions" {
  provider = google-beta
  project  = "gcp-onboarding-project-480819"
  role     = "roles/monitoring.viewer"
  member   = google_service_account.microservices_app_sa.member
}
