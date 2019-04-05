provider "aws" {
  version = "~> 1.60"
}

provider "template" {
  version = "~> 2.1"
}

provider "tls" {
  version = "~> 1.2"
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

variable "availability_zones" {
  type = "list"
}

variable "directory_name" {
  type    = "string"
  default = ""
}

variable "tags" {
  type        = "map"
  default     = {}
  description = "Key/value tags to assign to all AWS resources"
}

module "cidr_lookup" {
  source   = "../terraforming-aws/modules/calculate_subnets"
  vpc_cidr = "${var.transit_vpc_cidr}"
}

locals {
  infrastructure_cidr = "${module.cidr_lookup.infrastructure_cidr}"

  service_cidr = "${module.cidr_lookup.services_cidr}"

  public_cidr    = "${module.cidr_lookup.public_cidr}"
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

resource "aws_subnet" "infrastructure_subnets" {
  count             = "${length(var.availability_zones)}"
  vpc_id            = "${aws_vpc.transit_vpc.id}"
  cidr_block        = "${cidrsubnet(local.infrastructure_cidr, 2, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-infrastructure-subnet${count.index}"))}"
}

resource "aws_subnet" "public_subnets" {
  count             = "${length(var.availability_zones)}"
  vpc_id            = "${aws_vpc.transit_vpc.id}"
  cidr_block        = "${cidrsubnet(local.public_cidr, 2, count.index)}"
  availability_zone = "${element(var.availability_zones, count.index)}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-public-subnet${count.index}"))}"
}

resource "aws_subnet" "proxy_subnets" {
  count                   = "${length(var.availability_zones)}"
  vpc_id                  = "${aws_vpc.transit_vpc.id}"
  cidr_block              = "${cidrsubnet(local.service_cidr, 2, count.index)}"
  availability_zone       = "${element(var.availability_zones, count.index)}"
  map_public_ip_on_launch = false

  tags = "${merge(var.tags, map("Name", "${var.env_name}-proxy-subnet${count.index}"))}"
}

resource "aws_route_table" "public_route_table" {
  vpc_id = "${aws_vpc.transit_vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.ig.id}"
  }
}

resource "aws_route_table" "deployment" {
  count  = "${length(var.availability_zones)}"
  vpc_id = "${aws_vpc.transit_vpc.id}"
}

resource "aws_route_table" "pcf_to_peering" {
  vpc_id = "${aws_vpc.pcf_vpc.id}"

  route {
    cidr_block                = "${var.transit_vpc_cidr}"
    vpc_peering_connection_id = "${aws_vpc_peering_connection.vpc_peering.id}"
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-pcf-to-peering-route-table"))}"
}

resource "aws_route_table" "proxy_route_table" {
  count  = "${length(var.availability_zones)}"
  vpc_id = "${aws_vpc.transit_vpc.id}"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "${element(aws_nat_gateway.nat.*.id, count.index)}"
  }

  route {
    cidr_block                = "${var.pcf_vpc_cidr}"
    vpc_peering_connection_id = "${aws_vpc_peering_connection.vpc_peering.id}"
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat-peering-route-table${count.index}"))}"
}

resource "aws_route_table" "jumpbox_route_table" {
  count  = "${length(var.availability_zones)}"
  vpc_id = "${aws_vpc.transit_vpc.id}"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "${element(aws_nat_gateway.nat.*.id, count.index)}"
  }

  route {
    cidr_block                = "${var.pcf_vpc_cidr}"
    vpc_peering_connection_id = "${aws_vpc_peering_connection.vpc_peering.id}"
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-nat-peering-route-table${count.index}"))}"
}

resource "aws_route_table_association" "route_public_subnets" {
  count          = "${length(var.availability_zones)}"
  subnet_id      = "${element(aws_subnet.public_subnets.*.id, count.index)}"
  route_table_id = "${aws_route_table.public_route_table.id}"
}

resource "aws_route_table_association" "route_proxy_subnets" {
  count          = "${length(var.availability_zones)}"
  subnet_id      = "${element(aws_subnet.proxy_subnets.*.id, count.index)}"
  route_table_id = "${element(aws_route_table.proxy_route_table.*.id, count.index)}"
}

resource "aws_route" "proxy_route" {
  count                  = "${length(var.availability_zones)}"
  route_table_id         = "${aws_route_table.pcf_to_peering.id}"
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = "${element(aws_network_interface.proxy_interface.*.id, count.index)}"
}

resource "aws_security_group" "nat_security_group" {
  name        = "nat_security_group"
  description = "NAT Security Group"
  vpc_id      = "${aws_vpc.transit_vpc.id}"

  ingress {
    security_groups = ["${aws_security_group.proxy_security_group.id}", "${aws_security_group.jumpbox_security_group.id}"]
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

  tags = "${merge(var.tags, map("Name", "${var.env_name}-jumpbox-security-group"))}"
}

resource "aws_security_group" "proxy_security_group" {
  name   = "${var.env_name}_proxy_security_group"
  vpc_id = "${aws_vpc.transit_vpc.id}"

  # SSH access from jumpbox security group
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = ["${aws_security_group.jumpbox_security_group.id}"]
  }

  # Squid proxy port
  ingress {
    from_port   = 0
    to_port     = "443"
    protocol    = "tcp"
    self        = true
    cidr_blocks = ["${local.infrastructure_cidr}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-proxy-security-group"))}"
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

resource "aws_vpc_peering_connection" "vpc_peering" {
  peer_vpc_id = "${aws_vpc.pcf_vpc.id}"
  vpc_id      = "${aws_vpc.transit_vpc.id}"
  auto_accept = true

  tags = "${merge(var.tags, map("Name", "${var.env_name}-peering-to-pcf"))}"
}
