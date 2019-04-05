variable "directory_password" {}

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
