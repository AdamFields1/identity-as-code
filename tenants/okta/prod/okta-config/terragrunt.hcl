# Okta prod tenant cell.
#
# Values only. Same stack as dev; the differences below are the whole story of
# "what is stricter in production":
#   - shorter idle timeout and lifetime
#   - MFA required on every sign-on rule, including the corporate network
#   - MFA prompt ALWAYS when off-network
#   - longer minimum password, tighter lockout, longer auto-unlock
#
# State key (derived by root.hcl): okta/prod/okta-config/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/okta-config"
}

inputs = {
  okta_org_name = "example-org"
  okta_base_url = "okta.com"

  network_zones = {
    corp-egress = {
      name     = "Corporate egress"
      type     = "IP"
      usage    = "POLICY"
      gateways = ["203.0.113.0/24"]
    }

    vpn = {
      name     = "VPN concentrators"
      type     = "IP"
      usage    = "POLICY"
      gateways = ["198.51.100.0/24"]
    }

    deny-tor = {
      name               = "Blocklist: Tor exit nodes"
      type               = "DYNAMIC"
      usage              = "BLOCKLIST"
      dynamic_proxy_type = "TorAnonymizer"
    }
  }

  session_policy = {
    name            = "Workforce sign-on"
    priority        = 1
    groups_included = ["Everyone"]

    session_defaults = {
      idle_minutes      = 30
      lifetime_minutes  = 480
      persistent_cookie = false
    }

    rules = {
      corp-network = {
        name               = "Corporate network or VPN"
        priority           = 1
        mfa_required       = true
        mfa_prompt         = "SESSION"
        mfa_lifetime       = 240
        network_connection = "ZONE"
        zones_included     = ["corp-egress", "vpn"]
      }

      anywhere = {
        name         = "Anywhere else"
        priority     = 2
        mfa_required = true
        mfa_prompt   = "ALWAYS"
        session_idle = 15
      }
    }
  }

  mfa_policy = {
    name            = "Workforce MFA enrollment"
    priority        = 1
    groups_included = ["Everyone"]
    is_oie          = true

    authenticators = {
      okta_password = { enroll = "REQUIRED" }
      okta_verify   = { enroll = "REQUIRED" }
      fido_webauthn = { enroll = "REQUIRED" }
      google_otp    = { enroll = "NOT_ALLOWED" }
      phone_number  = { enroll = "NOT_ALLOWED" }
    }

    rules = {
      default = {
        name     = "Enroll at next sign-in"
        priority = 1
        enroll   = "LOGIN"
      }
    }
  }

  password_policy = {
    name            = "Workforce password"
    priority        = 1
    groups_included = ["Everyone"]

    complexity = {
      min_length = 16
    }

    lockout = {
      max_attempts        = 5
      auto_unlock_minutes = 60
    }

    recovery = {
      email               = "ACTIVE"
      email_token_minutes = 30
      sms                 = "INACTIVE"
      call                = "INACTIVE"
      question            = "INACTIVE"
    }

    rules = {
      default = {
        name            = "Self-service allowed"
        priority        = 1
        password_change = "ALLOW"
        password_reset  = "ALLOW"
        password_unlock = "ALLOW"
      }
    }
  }
}
