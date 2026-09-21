terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 6.0.0"
    }

    # Packaging the bundled authorizer function is part of this module, so the
    # provider that does the packaging is declared here rather than left for the
    # caller to remember.
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}
