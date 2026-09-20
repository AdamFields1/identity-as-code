# Okta prod tenant: the application catalog cell's sign-on policies.
#
# A fragment of ./terragrunt.hcl, included there as "signon_policies": one
# inputs attribute holding signon_policies and nothing else. Values only, as
# the cell is; the header comment in terragrunt.hcl describes the whole cell.
#
# App sign-on policies. Keys are stable identifiers the app fragments name
# through signon_policy; renaming a key moves the policy in state and
# re-points every app on it, so change the display name instead. Zones are
# the names the okta-config cell creates, groups are names. The module
# creates every policy's catch-all rule with DENY, so each path to ALLOW is
# a rule written here, and a rule that allows single-factor access is
# refused unless the policy says allow_single_factor with a reason; neither
# policy below does.
#
# There is no policy for the service app. Client credentials has no user
# sign-in for an app sign-on policy to evaluate, the token endpoint
# authenticates the client by its keys, and the schema does not require a
# policy on the app, so the service entry in oauth-apps.hcl names none.

inputs = {
  signon_policies = {
    # The everyday policy. Two factors, re-authentication every twelve hours,
    # and a place the request comes from: a corporate zone, or a device a
    # management system vouches for. Anything else falls to the DENY
    # catch-all.
    standard-workforce = {
      name        = "Standard workforce"
      description = "Two factors every twelve hours from a corporate zone or a managed device. Managed by Terraform."

      rules = {
        corp-zones = {
          name                        = "Corporate egress or VPN"
          priority                    = 1
          access                      = "ALLOW"
          factor_mode                 = "2FA"
          re_authentication_frequency = "PT12H"
          network_connection          = "ZONE"
          network_zone_names          = ["Corporate egress", "VPN concentrators"]
        }

        managed-anywhere = {
          name                        = "Managed device, any network"
          priority                    = 2
          access                      = "ALLOW"
          factor_mode                 = "2FA"
          re_authentication_frequency = "PT12H"
          device_is_managed           = true
        }
      }
    }

    # The policy an admin-tier app must name. Possession must be phishing
    # resistant and hardware protected (a FIDO2 security key or a platform
    # authenticator), and PT0S re-authenticates on every sign-in. Who may
    # reach the app is the app's group assignment, not a group on this rule,
    # so a second admin app can share the policy.
    admin-phishing-resistant = {
      name        = "Admin phishing resistant"
      description = "Phishing-resistant, hardware-protected possession on every sign-in. Managed by Terraform."

      rules = {
        admins = {
          name                        = "Phishing-resistant, hardware-protected, every time"
          priority                    = 1
          access                      = "ALLOW"
          factor_mode                 = "2FA"
          re_authentication_frequency = "PT0S"

          constraints = {
            possession = {
              phishing_resistant = "REQUIRED"
              hardware_protected = "REQUIRED"
            }
          }
        }
      }
    }
  }
}
