terraform {
  required_providers {
    linode = {
      source = "linode/linode"
      version = "2.13.0"
    }
  }
}

# Variables & Data
locals {
  app_name = "tfVpcDemo"
}
variable "LINODE_TOKEN" {}
variable "DOMAIN" {}
variable "PORT" {}
variable "START_COMMAND" {}
variable "DB_NAME" {}
variable "DB_USER" {}
variable "DB_PASS" {}
variable "region" {
  type = string
  default = "us-sea" # see https://api.linode.com/v4/regions
}
variable "vpc_subnet_ip" {
  type = string
  default = "10.0.0.0/24" # see https://api.linode.com/v4/regions
}

# # output "foo" {
# #   value = { for tuple in regexall("(.*?)=(.*)", file(".env")) : tuple[0] => tuple[1] }
# # }

data "linode_domain" "domain" {
  domain = var.DOMAIN
}

# Configure the Linode Provider
provider "linode" {
  token = var.LINODE_TOKEN
}

resource "linode_sshkey" "ssh_key" {
  label = "my_ssh_key"
  ssh_key = chomp(file("~/.ssh/id_ed25519.pub"))
}

# VPC
resource "linode_vpc" "vpc" {
  label = "${local.app_name}-vpc"
  region = var.region
}
resource "linode_vpc_subnet" "vpc_subnet" {
  vpc_id = linode_vpc.vpc.id
  label = "${local.app_name}-vpc-subnet"
  ipv4 = "${var.vpc_subnet_ip}"
}

# VPS
resource "linode_instance" "application" {
  image = "linode/ubuntu20.04"
  type = "g6-nanode-1"
  label = "${local.app_name}-linode1"
  group = "${local.app_name}-group"
  region = var.region
  authorized_keys = [ linode_sshkey.ssh_key.ssh_key ]

  interface {
    purpose = "public"
  }
  interface {
    purpose   = "vpc"
    subnet_id = linode_vpc_subnet.vpc_subnet.id
    # ip_ranges = [var.vpc_subnet_ip]
    ipv4 {
      vpc = "10.0.0.2"
    }
  }
}

# configure web nodes
resource "null_resource" "copy_files" {
  connection {
    type = "ssh"
    user = "root"
    agent = "true"
    host = "${linode_instance.application.ip_address}"
  }
  provisioner "remote-exec" {
    inline = [
      "mkdir qwik-app"
    ]
  }
  provisioner "file" {
    source      = "app.mjs"
    destination = "app.mjs" 
  }
  provisioner "file" {
    source      = "server-init.sh"
    destination = "server-init.sh" 
  }
  provisioner "file" {
    source      = "qwik-app/"
    destination = "qwik-app"
  }
}
resource "null_resource" "configure_server" {
  depends_on = [
    null_resource.copy_files
  ]
  connection {
    type = "ssh"
    user = "root"
    agent = "true"
    host = "${linode_instance.application.ip_address}"
  }
  provisioner "remote-exec" {
    inline = [
      # Must be same command, not comma-separated
      # "DOMAIN=${var.DOMAIN} PORT=${var.PORT} DB_HOST=${linode_instance.application.ip_address} START_COMMAND=${var.START_COMMAND} bash ./server-init.sh"
      "DOMAIN=${var.DOMAIN} PORT=${var.PORT} DB_HOST=${linode_instance.application.ip_address} START_COMMAND=\"node app/server/entry.node-server\" bash ./server-init.sh"
    ]
  }
}

# Domain/DNS
resource "linode_domain_record" "dns_record" {
  domain_id = "${data.linode_domain.domain.id}"
  record_type = "A"
  target = "${linode_instance.database.ip_address}"
}

# Database
resource "linode_stackscript" "db_setup" {
  label = "${local.app_name}-db"
  description = "Installs a Package"
  script = <<EOF
#!/bin/bash
apt update && apt install postgresql -y && systemctl start postgresql.service;
sudo -u postgres createdb ${var.DB_NAME}
sudo -u postgres psql -c "CREATE USER ${var.DB_USER} WITH ENCRYPTED PASSWORD '${var.DB_PASS}'; GRANT ALL PRIVILEGES ON DATABASE ${var.DB_NAME} TO ${var.DB_USER};"
echo "listen_addresses = '*'" >> /etc/postgresql/12/main/postgresql.conf 
echo "host all all all md5" >> /etc/postgresql/12/main/pg_hba.conf
sudo systemctl restart postgresql
EOF
  images = ["linode/ubuntu20.04"]
}
# echo "host all all ${var.vpc_subnet_ip} md5" >> /etc/postgresql/12/main/pg_hba.conf

resource "linode_instance" "database" {
  image = "linode/ubuntu20.04"
  type = "g6-nanode-1"
  label = "${local.app_name}-db"
  group = "${local.app_name}-group"
  region = var.region
  authorized_keys = [ linode_sshkey.ssh_key.ssh_key ]
  stackscript_id = linode_stackscript.db_setup.id
}

# - upload source files

# resource "local_file" "env_file" {
#   content  = <<EOT
# DOMAIN=${var.DOMAIN}
# DB_USER=${linode_database_postgresql.database.root_username}
# DB_PASS=${linode_database_postgresql.database.root_password}
# EOT
#   filename = "${path.module}/.env"
# }