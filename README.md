# High Security Infrastructure

The goal here is to create an Active Directory service that can be used for account creation inside PCF and then also enabling a transparent SSL proxy using squid to mimick similar restrictions on an internetless PCF installation following a hub-spoke model.  Lastly, we peer this VPC over to your PCF infrastructure.

This assumes you have **not** paved your infrastructure already using terraforming-aws, and since this is still an experimental POC you'll notice it actually refers to this module as well.  Hopefully I can clean that up later.

Before we begin, we'll need to generate some certificates for the squid proxy.

```
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 365 -key ca.key -subj "/C=US/ST=MD/L=EC/O=Acme, Inc./CN=Acme Root CA" -out ca.crt
openssl req -newkey rsa:2048 -nodes -keyout ca2.key -subj "/C=US/ST=MD/L=EC/O=Acme, Inc./CN=Acme Root CA2" -out ca2.csr
openssl x509 -req -days 365 -in ca2.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ca2.crt
cat ca.crt ca2.crt > ca1ca2chain.pem
export TF_VAR_ssl_ca_cert="$(cat ca1ca2chain.pem)"
export TF_VAR_ssl_ca_private_key="$(cat ca2.key)"
```

Use the contents of those files to populate the `terraform.tfvars` file:

```
env_name = "dev"
dns_suffix = "pivdevops.com"
availability_zones = ["us-east-1a", "us-east-1d"]
directory_password = "SUPER SECURE PASSWORD"
pcf_vpc_id = "vpc-PCFVPCID"

tags = {
  Team    = "Dev"
  Project = "WebApp3"
  Fish    = "Food"
  Dogs    = "Cats"
}
```

Optionally put the contents of the certificates into the `terraform.tfvars` like this:
```
ssl_ca_cert = <<EOF
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
EOF

ssl_ca_private_key = <<EOF
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
EOF
```
