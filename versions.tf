terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # Floor and ceiling are both deliberate.
      #
      # The floor is 5.0.0 because every argument this configuration uses on
      # the apigatewayv2 resources has been present since the 5.x line opened.
      # Nothing here reaches for an attribute added later, so raising the floor
      # would exclude versions that work.
      #
      # The ceiling is 6.0.0 because the 6.x line changes provider defaults and
      # argument availability across several services, and none of that has been
      # exercised against this configuration. Lifting it is a deliberate piece of
      # work rather than a version bump.
      version = ">= 5.0.0, < 6.0.0"
    }
  }
}
