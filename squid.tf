variable "ssl_ca_cert" {}

variable "ssl_ca_private_key" {}

variable "squid_docker_image" {
  default = "voor/squid4"
}

resource "aws_instance" "squid_proxy" {
  count         = "${length(var.availability_zones)}"
  ami           = "${data.aws_ami.ubuntu_ami.id}"
  instance_type = "t2.micro"
  key_name      = "${aws_key_pair.squid_proxy.key_name}"

  network_interface {
    network_interface_id = "${element(aws_network_interface.proxy_interface.*.id, count.index)}"
    device_index         = 0
  }
  user_data = "${data.template_file.squid_payload.rendered}"
  root_block_device {
    volume_type = "gp2"
    volume_size = 150
  }
  tags = "${merge(var.tags, map("Name", "${var.env_name}-squid-proxy-${element(var.availability_zones, count.index)}"))}"
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

resource "aws_network_interface" "proxy_interface" {
  count     = "${length(var.availability_zones)}"
  subnet_id = "${element(aws_subnet.proxy_subnets.*.id, count.index)}"

  security_groups = ["${aws_security_group.proxy_security_group.id}"]

  # Important to disable this check to allow traffic not addressed to the
  # proxy to be received
  source_dest_check = false

  tags = "${merge(var.tags, map("Name", "${var.env_name}-squid-proxy-interface-${element(var.availability_zones, count.index)}"))}"
}
