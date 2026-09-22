terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # The same span the repository pins, and this module stays inside it
      # deliberately rather than reaching for attributes added partway through.
      #
      # The one that matters is evaluation_window_sec on a rate-based
      # statement. It does not exist at 5.0.0, so a configuration using it
      # cannot be planned on every provider this range resolves to. The window
      # is therefore left at the service default of five minutes and the
      # consequence is written into the rate-limit input rather than hidden:
      # the limit is counted per window, not per second.
      version = ">= 5.0.0, < 6.0.0"
    }
  }
}
