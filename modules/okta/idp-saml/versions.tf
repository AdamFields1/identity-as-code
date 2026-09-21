terraform {
  required_version = ">= 1.9.0"

  required_providers {
    okta = {
      source  = "okta/okta"
      version = "~> 4.20"
    }
  }
}
