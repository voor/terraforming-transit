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
