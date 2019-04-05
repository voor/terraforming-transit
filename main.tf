provider "aws" {
  version = "~> 1.60"
}

terraform {
  required_version = "< 0.12.0"
}

variable "transit_vpc_cidr" {
  type    = "string"
  default = "10.10.0.0/16"
}

variable "pcf_vpc_cidr" {
  type    = "string"
  default = "10.0.0.0/16"
}

variable "env_name" {}

variable "dns_suffix" {}

variable "squid_docker_image" {
  default = "voor/squid4"
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

resource "aws_vpc" "transit_vpc" {
  cidr_block = "${var.transit_vpc_cidr}"

  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = "${merge(var.tags, map("Name", "${var.env_name}-transit-vpc"))}"
}

resource "aws_vpc" "pcf_vpc" {
  cidr_block = "${var.pcf_vpc_cidr}"

  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = "${merge(var.tags, map("Name", "${var.env_name}-vpc"))}"
}

resource "aws_internet_gateway" "ig" {
  vpc_id = "${aws_vpc.transit_vpc.id}"

  tags = "${var.tags}"
}

resource "aws_directory_service_directory" "directory" {
  name     = "${local.directory_name}"
  password = "${var.directory_password}"
  size     = "Small"

  vpc_settings {
    vpc_id     = "${aws_vpc.transit_vpc.id}"
    subnet_ids = ["${aws_subnet.infrastructure_subnets.*.id}"]
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-directory"))}"
}

resource "aws_subnet" "infrastructure_subnets" {
  count             = "${length(var.availability_zones)}"
  vpc_id            = "${aws_vpc.transit_vpc.id}"
  cidr_block        = "${cidrsubnet(local.infrastructure_cidr, 2, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-infrastructure-subnet${count.index}"))}"
}

resource "aws_route_table" "public_route_table" {
  vpc_id = "${aws_vpc.transit_vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.ig.id}"
  }
}

resource "aws_subnet" "public_subnets" {
  count             = "${length(var.availability_zones)}"
  vpc_id            = "${aws_vpc.transit_vpc.id}"
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
  vpc_id = "${aws_vpc.transit_vpc.id}"
}

resource "aws_security_group" "nat_security_group" {
  name        = "nat_security_group"
  description = "NAT Security Group"
  vpc_id      = "${aws_vpc.transit_vpc.id}"

  ingress {
    security_groups = ["${aws_security_group.proxy_security_group.id}"]
    protocol        = "-1"
    from_port       = 0
    to_port         = 0
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat-security-group"))}"
}

resource "aws_security_group" "jumpbox_security_group" {
  name   = "${var.env_name}_jumpbox_security_group"
  vpc_id = "${aws_vpc.transit_vpc.id}"

  # SSH access only
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.environment_name}_sg_1"
  }
}

resource "aws_security_group" "proxy_security_group" {
  name   = "${var.env_name}_proxy_security_group"
  vpc_id = "${aws_vpc.transit_vpc.id}"

  # SSH access from jumpbox security group
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = ["${aws_security_group.jumpbox.id}"]
  }

  # Squid proxy port
  ingress {
    to_port     = "443"
    protocol    = "tcp"
    self        = true
    cidr_blocks = ["${locals.infrastructure_cidr}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.environment_name}_sg_3"
  }
}

resource "aws_nat_gateway" "nat" {
  count         = "${length(var.availability_zones)}"
  allocation_id = "${element(aws_eip.nat_eip.*.id, count.index)}"
  subnet_id     = "${element(aws_subnet.public_subnets.*.id, count.index)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat-${element(var.availability_zones, count.index)}"))}"
}

resource "aws_eip" "nat_eip" {
  count = "${length(var.availability_zones)}"
  vpc   = true

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat-eip-${element(var.availability_zones, count.index)}"))}"
}

resource "aws_route" "toggle_internet" {
  count = "${length(var.availability_zones)}"

  route_table_id         = "${element(aws_route_table.deployment.*.id, count.index)}"
  nat_gateway_id         = "${element(aws_nat_gateway.nat.*.id, count.index)}"
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

variable "ssl_ca_cert" {}

variable "ssl_ca_private_key" {}

resource "aws_instance" "squid_proxy" {
  ami                    = "${data.aws_ami.ubuntu_ami}"
  instance_type          = "t2.micro"
  key_name               = "${aws_key_pair.squid_proxy.key_name}"
  vpc_security_group_ids = ["${aws_security_group.ops_manager_security_group.id}"]
  source_dest_check      = false
  subnet_id              = "${element(aws_subnet.public_subnets.*.id, 0)}"
  iam_instance_profile   = "${aws_iam_instance_profile.nat_security_group.name}"
  count                  = "${var.vm_count}"

  network_interface {
    network_interface_id = "${aws_network_interface.proxy.id}"
    device_index         = 0
  }

  user_data = "${data.tem.squid_payload}"

  root_block_device {
    volume_type = "gp2"
    volume_size = 150
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-squid-proxy"))}"
}

resource "aws_key_pair" "squid_proxy" {
  key_name   = "${var.env_name}-squid-proxy-key"
  public_key = "${tls_private_key.squid_proxy_key.public_key_openssh}"
}

resource "tls_private_key" "squid_proxy_key" {
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
    squid_docker_image = "${var.squid_docker_image}"
    ssl_ca_cert        = "${var.ssl_ca_cert}"
    ssl_ca_private_key = "${var.ssl_ca_private_key}"
  }
}

resource "aws_network_interface" "proxy" {
  subnet_id = "${element(aws_subnet.public_subnets.*.id, 0)}"

  # Important to disable this check to allow traffic not addressed to the
  # proxy to be received
  source_dest_check = false
}
