# An API Gateway API is a regional resource: the API, its stage, its access log
# group and the integrations it reaches all live in one region, and an API
# cannot span regions. A deployment therefore targets exactly one region, and a
# second region means a second deployment of this configuration rather than a
# second provider block here.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.default_tags
  }
}
