variable "use_route53" {
  default = false
}

variable "hosted_zone" {}

locals {
  data_zone_id     = "${element(concat(data.aws_route53_zone.pcf_zone.*.zone_id, list("")), 0)}"
  resource_zone_id = "${element(concat(aws_route53_zone.pcf_zone.*.zone_id, list("")), 0)}"
  zone_id          = "${var.hosted_zone == "" ? local.resource_zone_id : local.data_zone_id}"

  data_dns_name_servers     = "${join(",", flatten(concat(data.aws_route53_zone.pcf_zone.*.name_servers, list(list("")))))}"
  resource_dns_name_servers = "${join(",", flatten(concat(aws_route53_zone.pcf_zone.*.name_servers, list(list("")))))}"
  name_servers              = "${var.hosted_zone == "" ? local.resource_dns_name_servers : local.data_dns_name_servers}"
  hosted_zone_count         = "${var.hosted_zone == "" ? 0 : 1}"
}

resource "aws_instance" "jumpbox" {
  count         = 1
  ami           = "${data.aws_ami.ubuntu_ami.id}"
  instance_type = "t2.micro"
  key_name      = "${aws_key_pair.jumpbox_pair.key_name}"

  subnet_id       = "${element(aws_subnet.public_subnets.*.id, count.index)}"
  vpc_security_group_ids = ["${aws_security_group.jumpbox_security_group.id}"]

  root_block_device {
    volume_type = "gp2"
    volume_size = 150
  }

  tags = "${merge(var.tags, map("Name", "${var.env_name}-jumpbox-${element(var.availability_zones, count.index)}"))}"
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

resource "aws_key_pair" "jumpbox_pair" {
  key_name   = "${var.env_name}-jumpbox-key"
  public_key = "${tls_private_key.jumpbox_key.public_key_openssh}"
}

resource "tls_private_key" "jumpbox_key" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

output "jumpbox_ssh_private_key" {
  value = "${element(concat(tls_private_key.jumpbox_key.*.private_key_pem, list("")), 0)}"
}

resource "aws_eip" "jumpbox_eip" {
  count    = "1"
  vpc      = true
  instance = "${aws_instance.jumpbox.id}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-jumpbox-eip-${element(var.availability_zones, count.index)}"))}"
}

data "aws_route53_zone" "pcf_zone" {
  count = "${var.use_route53 ? local.hosted_zone_count : 0}"

  name = "${var.hosted_zone}"
}

resource "aws_route53_zone" "pcf_zone" {
  count = "${var.use_route53 ? (1 - local.hosted_zone_count) : 0}"

  name = "${var.env_name}.${var.dns_suffix}"

  tags = "${merge(var.tags, map("Name", "${var.env_name}-hosted-zone"))}"
}

resource "aws_route53_record" "name_servers" {
  count = "${var.use_route53 ? (1 - local.hosted_zone_count) : 0}"

  zone_id = "${local.zone_id}"
  name    = "${var.env_name}.${var.dns_suffix}"

  type = "NS"
  ttl  = 300

  records = ["${local.name_servers}"]
}

resource "aws_route53_record" "jumpbox_eip" {
  name    = "jumpbox.${var.env_name}.${var.dns_suffix}"
  zone_id = "${local.zone_id}"
  type    = "A"
  ttl     = 300
  count   = "${var.use_route53 ? 1 : 0}"

  records = ["${aws_eip.jumpbox_eip.public_ip}"]
}

output "jumpbox_dns" {
  value = "${element(concat(aws_route53_record.jumpbox_eip.*.name, list("")), 0)}"
}
