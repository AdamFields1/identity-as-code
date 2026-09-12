# Entra corp tenant cell: Conditional Access.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Sample policy set:
#   CA001 block legacy authentication          report-only (subsidiary enforces)
#   CA002 phishing-resistant MFA for PIM groups enforced
#   CA003 MFA for all users, trusted egress exempt   enforced
#   CA004 sign-in risk requires MFA             report-only in every tenant
#
# Every policy excludes "SEC Break Glass Accounts". That is not listed per
# policy because the module appends it; it cannot be forgotten.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/entra-conditional-access/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-conditional-access"
}

inputs = {
  break_glass_exclusion_group = "SEC Break Glass Accounts"

  # -------------------------------------------------------------------------
  # Named locations. Keys are stable identifiers used by policies below.
  # CIDRs are RFC 5737 documentation ranges; replace with real egress ranges.
  # -------------------------------------------------------------------------
  named_locations = {
    corp-egress = {
      display_name = "Corporate egress"
      ip_ranges    = ["203.0.113.0/24"]
      trusted      = true
    }

    vpn = {
      display_name = "VPN concentrators"
      ip_ranges    = ["198.51.100.0/24"]
      trusted      = true
    }

    allowed-countries = {
      display_name = "Allowed countries"
      countries    = ["US", "CA", "GB"]
    }
  }

  # -------------------------------------------------------------------------
  # Authentication strengths.
  # -------------------------------------------------------------------------
  authentication_strengths = {
    phishing-resistant = {
      display_name         = "Phishing-resistant MFA"
      description          = "Passkeys, Windows Hello for Business, or certificate-based authentication."
      allowed_combinations = ["windowsHelloForBusiness", "fido2", "x509CertificateMultiFactor"]
    }
  }

  # -------------------------------------------------------------------------
  # Policies. New policies default to report-only; "state" is only written
  # here when a policy has been promoted after reading the report-only data.
  # -------------------------------------------------------------------------
  policies = {
    block-legacy-auth = {
      display_name     = "CA001 Block legacy authentication"
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
          "PIM User Administrators",
        ]
      }

      grant_controls = { authentication_strength = "phishing-resistant" }
    }

    require-mfa-all-users = {
      display_name = "CA003 Require MFA for all users"
      state        = "enabled"

      # Exclusions are named groups, never individual users, so every exemption
      # has an owner and shows up in an access review. The break-glass group is
      # appended by the module and is deliberately not listed here.
      users = {
        included_users  = ["All"]
        excluded_groups = ["CA Exclusion MFA Legacy Devices", "SVC Non-Interactive Accounts"]
      }
      locations = { included = ["All"], excluded = ["corp-egress", "vpn"] }

      grant_controls = { built_in_controls = ["mfa"] }

      session_controls = {
        sign_in_frequency        = 12
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
