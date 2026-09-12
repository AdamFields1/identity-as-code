# Okta dev tenant cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# State key (derived by root.hcl): okta/dev/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../stacks/okta-config"
}

inputs = {
  okta_org_name = "example-org-dev"
  okta_base_url = "oktapreview.com"

  # -------------------------------------------------------------------------
  # Network zones. Keys are stable identifiers used by rules below.
  # CIDRs are RFC 5737 documentation ranges; replace with real egress ranges.
  # -------------------------------------------------------------------------
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

  # -------------------------------------------------------------------------
  # Sign-on policy. Dev is relaxed on the corporate network so engineers can
  # iterate, and still requires MFA from anywhere else.
  # -------------------------------------------------------------------------
  session_policy = {
    name            = "Workforce sign-on (dev)"
    priority        = 1
    groups_included = ["Everyone"]

    session_defaults = {
      idle_minutes      = 120
      lifetime_minutes  = 720
      persistent_cookie = false
    }

    rules = {
      corp-network = {
        name               = "Corporate network or VPN"
        priority           = 1
        mfa_required       = false
        network_connection = "ZONE"
        zones_included     = ["corp-egress", "vpn"]
      }

      anywhere = {
        name         = "Anywhere else"
        priority     = 2
        mfa_required = true
        mfa_prompt   = "SESSION"
        mfa_lifetime = 480
      }
    }
  }

  # -------------------------------------------------------------------------
  # MFA enrollment.
  # -------------------------------------------------------------------------
  mfa_policy = {
    name            = "Workforce MFA enrollment (dev)"
    priority        = 1
    groups_included = ["Everyone"]
    is_oie          = true

    authenticators = {
      okta_password = { enroll = "REQUIRED" }
      okta_verify   = { enroll = "REQUIRED" }
      fido_webauthn = { enroll = "OPTIONAL" }
      google_otp    = { enroll = "OPTIONAL" }
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

  # -------------------------------------------------------------------------
  # Password policy. Module defaults are already strict; dev only overrides
  # the lockout window so test accounts recover faster.
  # -------------------------------------------------------------------------
  password_policy = {
    name            = "Workforce password (dev)"
    priority        = 1
    groups_included = ["Everyone"]

    lockout = {
      max_attempts        = 10
      auto_unlock_minutes = 15
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
