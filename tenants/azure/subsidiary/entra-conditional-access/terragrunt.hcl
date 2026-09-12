# Entra subsidiary tenant cell: Conditional Access.
#
# Values only. Same stack as corp; the differences below are the whole story of
# "what is stricter in the subsidiary":
#   - CA001 legacy authentication block is enforced, not report-only
#   - CA003 MFA for all users has no trusted-location exemption
#   - shorter sign-in frequency
#
# CA004 (sign-in risk) stays report-only in every tenant until its data has
# been read.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/subsidiary/entra-conditional-access/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-conditional-access"
}

inputs = {
  break_glass_exclusion_group = "SEC Break Glass Accounts"

  named_locations = {
    office-egress = {
      display_name = "Subsidiary office egress"
      ip_ranges    = ["192.0.2.0/24"]
      trusted      = true
    }

    allowed-countries = {
      display_name = "Allowed countries"
      countries    = ["US", "GB"]
    }
  }

  authentication_strengths = {
    phishing-resistant = {
      display_name         = "Phishing-resistant MFA"
      description          = "Passkeys, Windows Hello for Business, or certificate-based authentication."
      allowed_combinations = ["windowsHelloForBusiness", "fido2", "x509CertificateMultiFactor"]
    }
  }

  policies = {
    block-legacy-auth = {
      display_name     = "CA001 Block legacy authentication"
      state            = "enabled"
      client_app_types = ["exchangeActiveSync", "other"]
      users            = { included_users = ["All"] }
      grant_controls   = { built_in_controls = ["block"] }
    }

    require-phishing-resistant-privileged = {
      display_name = "CA002 Require phishing-resistant MFA for privileged groups"
      state        = "enabled"

      users = {
        included_groups = [
          "PIM Global Administrators",
          "PIM Security Administrators",
        ]
      }

      grant_controls = { authentication_strength = "phishing-resistant" }
    }

    require-mfa-all-users = {
      display_name = "CA003 Require MFA for all users"
      state        = "enabled"

      users          = { included_users = ["All"] }
      grant_controls = { built_in_controls = ["mfa"] }

      session_controls = {
        sign_in_frequency        = 8
        sign_in_frequency_period = "hours"
        persistent_browser_mode  = "never"
      }
    }

    sign-in-risk-requires-mfa = {
      display_name        = "CA004 Sign-in risk medium or high requires MFA"
      users               = { included_users = ["All"] }
      sign_in_risk_levels = ["medium", "high"]
      grant_controls      = { built_in_controls = ["mfa"] }
    }
  }
}
