terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.4.2"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 4.15"
    }
  }
}

variable "project_id" {
  description = "Which Google Compute Project should your workspace live in?"
}

variable "zone" {
  description = "What region should your workspace live in?"
  default     = "us-central1-a"
  validation {
    condition     = contains(["northamerica-northeast1-a", "us-central1-a", "us-west2-c", "europe-west4-b", "southamerica-east1-a"], var.zone)
    error_message = "Invalid zone!"
  }
}

data "template_file" "sa_token" {
  template = file("gcp-default-key.json")
}

provider "google" {
  zone    = var.zone
  project = var.project_id
  credentials = "${file("gcp-default-key.json")}"
}

data "google_compute_default_service_account" "default" {
}

variable "dotfiles_uri" {
  description = <<-EOF
  Dotfiles repo URI (optional)

  see https://dotfiles.github.io
  EOF
  default = ""
}

data "coder_workspace" "me" {
}

resource "google_compute_disk" "root" {
  name  = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
  type  = "pd-ssd"
  zone  = var.zone
  #image = "debian-cloud/debian-9"
  image = "projects/coder-demo-1/global/images/coder-ubuntu-2004-lts-with-docker-engine"
  lifecycle {
    ignore_changes = [image]
  }
}

resource "coder_agent" "dev" {
  auth = "google-instance-identity"
  arch = "amd64"
  os   = "linux"
  startup_script = <<EOT
#!/bin/bash

# use coder CLI to clone and install dotfiles

coder dotfiles -y ${var.dotfiles_uri} 2>&1 > ~/dotfiles.log

# install and start code-server
curl -fsSL https://code-server.dev/install.sh | sh
code-server --auth none --port 13337 &

EOT
}  

# code-server
resource "coder_app" "code-server" {
  agent_id      = coder_agent.dev.id
  name          = "code-server"
  icon          = "/icon/code.svg"
  url           = "http://localhost:13337?folder=/home/coder"
  relative_path = true  
}

resource "google_compute_instance" "dev" {
  zone         = var.zone
  count        = data.coder_workspace.me.start_count
  name         = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
  machine_type = "e2-micro"
  network_interface {
    network = "default"
    access_config {
      // Ephemeral public IP
    }
  }
  boot_disk {
    auto_delete = false
    source      = google_compute_disk.root.name
  }
  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }
  # The startup script runs as root with no $HOME environment set up, which can break workspace applications, so
  # instead of directly running the agent init script, setup the home directory, write the init script, and then execute
  # it.
  metadata_startup_script = <<EOMETA
#!/usr/bin/env sh
set -eux pipefail

mkdir /root || true
cat <<'EOCODER' > /root/coder_agent.sh
${coder_agent.dev.init_script}
EOCODER
chmod +x /root/coder_agent.sh

export HOME=/root
/root/coder_agent.sh

EOMETA
}
