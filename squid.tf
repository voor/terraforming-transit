
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
