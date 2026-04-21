terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

variable "project_id" {
  type    = string
  default = "student-00465"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}


variable "alert_email" {
  type    = string
  default = "yousif2alrisi@gmail.com"
}



resource "google_compute_network" "yousif_vpc" {
  name                    = "yousif-vpc"
  auto_create_subnetworks = false
  mtu                     = 1460
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "public_subnet" {
  name          = "public-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.yousif_vpc.id
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "private-subnet"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = var.region
  network                  = google_compute_network.yousif_vpc.id
  private_ip_google_access = true
}

resource "google_compute_router" "yousif_router" {
  name    = "yousif-router"
  network = google_compute_network.yousif_vpc.id
  region  = var.region
  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "yousif_nat" {
  name                               = "yousif-nat"
  router                             = google_compute_router.yousif_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.private_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "allow_internal" {
  name      = "allow-internal"
  network   = google_compute_network.yousif_vpc.name
  priority  = 1000
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["10.0.0.0/8"]
}

resource "google_compute_firewall" "allow_http_https" {
  name      = "allow-http-https"
  network   = google_compute_network.yousif_vpc.name
  priority  = 1000
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  target_tags   = ["web-server"]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_health_check" {
  name      = "allow-health-check"
  network   = google_compute_network.yousif_vpc.name
  priority  = 1000
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
  target_tags   = ["web-server"]
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name      = "allow-ssh-iap"
  network   = google_compute_network.yousif_vpc.name
  priority  = 1000
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}

resource "google_compute_firewall" "deny_all_ingress" {
  name      = "deny-all-ingress"
  network   = google_compute_network.yousif_vpc.name
  priority  = 65534
  direction = "INGRESS"
  deny {
    protocol = "all"
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_service_account" "web_server_sa" {
  account_id   = "web-server-sa"
  display_name = "Web Server Service Account"
  project      = var.project_id
}

resource "google_compute_instance_template" "yousif_web_template" {
  name_prefix  = "yousif-web-template-"
  machine_type = "n1-standard-1"
  region       = var.region
  tags         = ["web-server"]

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-standard"
  }

  network_interface {
    network    = google_compute_network.yousif_vpc.id
    subnetwork = google_compute_subnetwork.private_subnet.id
  }

  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
    INSTANCE=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/name" -H "Metadata-Flavor: Google")
    cat > /var/www/html/index.html << HTML
    <!DOCTYPE html>
    <html>
    <head><title>Yousif Enterprise GCP</title></head>
    <body>
    <h1>Yousif Enterprise GCP Infrastructure</h1>
    <h2>Instance: $INSTANCE</h2>
    <p>Status: Healthy</p>
    </body>
    </html>
    HTML
    echo "healthy" > /var/www/html/health
  SCRIPT

  service_account {
    email  = google_service_account.web_server_sa.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_service_account.web_server_sa]
}

resource "google_compute_health_check" "http_health_check" {
  name = "http-health-check"
  http_health_check {
    port         = 80
    request_path = "/"
  }
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_instance_group_manager" "web_mig" {
  name               = "web-mig"
  base_instance_name = "yousif-web"
  zone               = var.zone

  version {
    instance_template = google_compute_instance_template.yousif_web_template.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.http_health_check.id
    initial_delay_sec = 120
  }
}

resource "google_compute_autoscaler" "web_autoscaler" {
  name   = "yousif-web-autoscaler"
  zone   = var.zone
  target = google_compute_instance_group_manager.web_mig.id

  autoscaling_policy {
    min_replicas    = 2
    max_replicas    = 5
    cooldown_period = 60
    cpu_utilization {
      target = 0.7
    }
  }
}

resource "google_compute_global_address" "lb_ip" {
  name         = "lb-ip"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
}

resource "google_compute_backend_service" "web_backend" {
  name                  = "web-backend"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  enable_cdn            = false
  load_balancing_scheme = "EXTERNAL"

  backend {
    group           = google_compute_instance_group_manager.web_mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  health_checks = [google_compute_health_check.http_health_check.id]

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "yousif_url_map" {
  name            = "yousif-url-map"
  default_service = google_compute_backend_service.web_backend.id
}

resource "google_compute_target_http_proxy" "yousif_http_proxy" {
  name    = "yousif-http-proxy"
  url_map = google_compute_url_map.yousif_url_map.id
}

resource "google_compute_global_forwarding_rule" "yousif_forwarding_rule" {
  name                  = "frontend"
  target                = google_compute_target_http_proxy.yousif_http_proxy.id
  port_range            = "80"
  ip_address            = google_compute_global_address.lb_ip.address
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
}

resource "google_compute_global_address" "db_private_ip_range" {
  name          = "yousif-db-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.yousif_vpc.id
}

resource "google_service_networking_connection" "db_connection" {
  network                 = google_compute_network.yousif_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.db_private_ip_range.name]
  depends_on              = [google_project_service.apis]
}

resource "google_sql_database_instance" "mysql_db" {
  name             = "mysql-db"
  database_version = "MYSQL_8_0"
  region           = var.region
  deletion_protection = false

  settings {
    tier              = "db-n1-standard-4"
    availability_type = "ZONAL"
    disk_size         = 250
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.yousif_vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
      start_time         = "02:00"
    }

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }
  }

  depends_on = [google_service_networking_connection.db_connection]
}

resource "google_sql_database" "yousif_database" {
  name     = "yousif-db"
  instance = google_sql_database_instance.mysql_db.name
  charset  = "utf8"
}

resource "google_sql_user" "admin_user" {
  name     = "admin"
  instance = google_sql_database_instance.mysql_db.name
  password = var.db_password
  host     = "%"
}


resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloudsql_sa.email}"
}

resource "google_monitoring_notification_channel" "alert_email" {
  display_name = "Alert Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "high_cpu" {
  display_name = "High CPU Usage Alert"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "CPU Utilization above 80 percent"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.alert_email.id]

  documentation {
    content   = "CPU usage exceeded 80% for more than 5 minutes. Investigate affected instances."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "instance_down" {
  display_name = "Instance Down Alert"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "VM Instance Unreachable"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/uptime\""
      duration        = "60s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.alert_email.id]

  documentation {
    content   = "A VM instance is unreachable. Check instance status immediately."
    mime_type = "text/markdown"
  }
}