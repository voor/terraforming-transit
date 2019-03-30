provider "aws" {
  version = "~> 1.60"
}

terraform {
  required_version = "< 0.12.0"
}

variable "vpc_cidr" {
  type    = "string"
  default = "10.10.0.0/16"
}

variable "env_name" {}

variable "dns_suffix" {}

variable "squid_docker_image" {
  default = "voor/squid4"
}

variable "pcf_vpc_id" {
  default = ""
}

variable "availability_zones" {
  type = "list"
}

variable "directory_name" {
  type    = "string"
  default = ""
}

variable "directory_password" {}

variable "tags" {
  type        = "map"
  default     = {}
  description = "Key/value tags to assign to all AWS resources"
}

locals {
  directory_name = "${var.directory_name != "" ? var.directory_name : "corp.${var.env_name}.${var.dns_suffix}" }"
}

resource "aws_vpc" "vpc" {
  cidr_block = "${var.vpc_cidr}"

  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = "${merge(var.tags, map("Name", "${var.env_name}-vpc"))}"
}

resource "aws_internet_gateway" "ig" {
  vpc_id = "${aws_vpc.vpc.id}"

  tags = "${var.tags}"
}

resource "aws_directory_service_directory" "directory" {
  name     = "${local.directory_name}"
  password = "${var.directory_password}"
  size     = "Small"

  vpc_settings {
    vpc_id     = "${aws_vpc.vpc.id}"
    subnet_ids = ["${aws_subnet.infrastructure_subnets.*.id}"]
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-directory"))}"
}

resource "aws_subnet" "infrastructure_subnets" {
  count             = "${length(var.availability_zones)}"
  vpc_id            = "${aws_vpc.vpc.id}"
  cidr_block        = "${cidrsubnet(local.infrastructure_cidr, 2, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-infrastructure-subnet${count.index}"))}"
}

resource "aws_route_table" "public_route_table" {
  vpc_id = "${aws_vpc.vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.ig.id}"
  }
}

resource "aws_subnet" "public_subnets" {
  count             = "${length(var.availability_zones)}"
  vpc_id            = "${aws_vpc.vpc.id}"
  cidr_block        = "${cidrsubnet(local.public_cidr, 2, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-public-subnet${count.index}"))}"
}

resource "aws_route_table_association" "route_public_subnets" {
  count          = "${length(var.availability_zones)}"
  subnet_id      = "${element(aws_subnet.public_subnets.*.id, count.index)}"
  route_table_id = "${aws_route_table.public_route_table.id}"
}

resource "aws_route_table" "deployment" {
  count  = "${length(var.availability_zones)}"
  vpc_id = "${aws_vpc.vpc.id}"
}

resource "aws_security_group" "nat_security_group" {
  name        = "nat_security_group"
  description = "NAT Security Group"
  vpc_id      = "${aws_vpc.vpc.id}"

  ingress {
    cidr_blocks = ["${var.vpc_cidr}"]
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat-security-group"))}"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = "${aws_eip.nat_eip.id}"
  subnet_id     = "${element(aws_subnet.public_subnets.*.id, 0)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat"))}"
}

resource "aws_eip" "nat_eip" {
  vpc = true

  tags = "${var.tags}"
}

resource "aws_route" "toggle_internet" {
  count = "${length(var.availability_zones)}"

  route_table_id         = "${element(aws_route_table.deployment.*.id, count.index)}"
  nat_gateway_id         = "${aws_nat_gateway.nat.id}"
  destination_cidr_block = "0.0.0.0/0"
}

module "cidr_lookup" {
  source   = "../terraforming-aws/modules/calculate_subnets"
  vpc_cidr = "${var.vpc_cidr}"
}

locals {
  infrastructure_cidr = "${module.cidr_lookup.infrastructure_cidr}"
  public_cidr         = "${module.cidr_lookup.public_cidr}"
}

resource "aws_vpc_peering_connection" "vpc_peering" {
  count       = "${var.pcf_vpc_id != "" ? 1 : 0}"
  peer_vpc_id = "${var.pcf_vpc_id}"
  vpc_id      = "${aws_vpc.vpc.id}"
  auto_accept = true

  tags = "${merge(var.tags, map("Name", "${var.env_name}-peering-to-pcf"))}"
}

resource "aws_instance" "squid_proxy" {
  ami                    = "${data.aws_ami.ubuntu_ami}"
  instance_type          = "t2.micro"
  key_name               = "${aws_key_pair.squid_proxy.key_name}"
  vpc_security_group_ids = ["${aws_security_group.ops_manager_security_group.id}"]
  source_dest_check      = false
  subnet_id              = "${element(aws_subnet.public_subnets.*.id, 0)}"
  iam_instance_profile   = "${aws_iam_instance_profile.ops_manager.name}"
  count                  = "${var.vm_count}"

  network_interface {
    network_interface_id = "${aws_network_interface.proxy.id}"
    device_index         = 0
  }

  user_data = <<-EOF
#!/bin/bash
set -x
sudo su -
apt update
apt install -y \
    apt-transport-https \
    ca-certificates \
    squid
mkdir -p /etc/squid
cat > /etc/systemd/system/squid.service << '_END'
[Unit]
Description=Squid4 Docker Container
Documentation=http://wiki.squid.org
After=network.target docker.service
Requires=docker.service

[Service]
ExecStartPre=-/usr/bin/docker kill squid4
ExecStartPre=-/usr/bin/docker rm squid4
ExecStart=/usr/bin/docker run --net=host --rm \
    -v /srv/squid/cache:/var/cache/squid4 \
    -v /etc/ssl/certs:/etc/ssl/certs:ro \
    -v /etc/ssl/private/ca.key:/etc/squid4/ssl_cert/ca.key:ro \
    -v /etc/ssl/certs/ca.crt:/etc/squid4/ssl_cert/ca.crt:ro \
    -v /etc/ssl/certs/chain.pem:/etc/ssl/certs/chain.pem:ro \
    -e CA_KEY=/ca.key \
    -e CA_CERT=/ca.crt \
    -e CA_CHAIN=/chain.pem \
    -e MITM_PROXY=yes \
    --name squid4 \
    "${var.squid_docker_image}"

[Install]
WantedBy=multi-user.target
_END
cat > /etc/ssl/certs/ca.crt <<'_END'
"${var.ssl_ca_cert}"
_END
cat > /etc/ssl/private/ca.key <<'_END'
"${var.ssl_ca_private_key}"
_END
cat > /etc/ssl/certs/chain.pem <<'_END'
"${var.ssl_ca_chain}"
_END
cat > /etc/squid/squid.conf <<'_END'
visible_hostname squid

#Handling HTTP requests
http_port 3129 intercept
# Do Not Allow ANY HTTP traffic.

#Handling HTTPS requests
https_port 3130 ssl-bump generate-host-certificates=on dynamic_cert_mem_cache_size=4MB \
cert=/etc/squid/ca.crt \
key=/etc/squid/ca.key \
cafile=/etc/squid/chain.pem intercept
sslproxy_flags DONT_VERIFY_PEER
sslproxy_cert_error deny all
acl SSL_port port 443
http_access allow SSL_port
acl allowed_https_sites ssl::server_name iam.amazonaws.com
#acl allowed_https_sites ssl::server_name [you can add other domains to permit]
acl step1 at_step SslBump1
acl step2 at_step SslBump2
acl step3 at_step SslBump3
ssl_bump peek step1 all
ssl_bump peek step2 allowed_https_sites
ssl_bump splice step3 allowed_https_sites
ssl_bump terminate step2 all

http_access deny all

_END

iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3129
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 3130
service iptables save
EOF

  root_block_device {
    volume_type = "gp2"
    volume_size = 150
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-squid-proxy"))}"
}

resource "aws_key_pair" "squid_proxy" {
  key_name   = "${var.env_name}-ops-manager-key"
  public_key = "${tls_private_key.ops_manager.public_key_openssh}"
}

resource "tls_private_key" "ops_manager" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

data "aws_ami" "ubuntu_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

data "template_file" "squid_payload" {
  template = "${file("squid_proxy.tpl")}"

  vars = {
    db_private_addr  = "${aws_instance.db.private_ip}"
    db_password      = "${var.db_password}"
    db_port          = "${var.db_port}"
    zbx_private_addr = "${aws_instance.app.private_ip}"
  }
}

resource "aws_network_interface" "proxy" {
  subnet_id = "${element(aws_subnet.public_subnets.*.id, 0)}"

  # Important to disable this check to allow traffic not addressed to the
  # proxy to be received
  source_dest_check = false
}
