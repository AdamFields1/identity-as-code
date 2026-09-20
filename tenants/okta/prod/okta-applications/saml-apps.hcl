# Okta prod tenant: the application catalog cell's SAML apps.
#
# A fragment of ./terragrunt.hcl, included there as "saml_apps": one inputs
# attribute holding saml_apps and nothing else. Values only, as the cell is;
# the header comment in terragrunt.hcl describes the whole cell.
#
# Custom SAML 2.0 apps. An entry is what the vendor's onboarding guide asks
# for: the assertion consumer service URL, the entity id it expects as the
# audience, the NameID format, the attributes the assertion carries, the
# groups whose members may open the app, and the sign-on policy by key.
# Signing (RSA-SHA256, SHA256, response and assertion), honor_force_authn,
# no self-service assignment, https-only endpoints, and no inline hook are
# fixed by the module and not on the menu. After apply, the stack's
# saml_vendor_onboarding output holds the entity id, SSO URL, metadata URL,
# and signing certificate the vendor configures on their side.

inputs = {
  saml_apps = {
    # The payroll vendor. The group statement is filtered to the app's own
    # groups so the vendor never sees the rest of the directory.
    payroll = {
      label                  = "Example Payroll"
      sso_url                = "https://payroll.example.com/saml/acs"
      audience               = "https://payroll.example.com"
      subject_name_id_format = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

      attribute_statements = [
        { name = "email", type = "EXPRESSION", values = ["user.email"] },
        { name = "name", type = "EXPRESSION", values = ["user.displayName"] },
        { name = "groups", type = "GROUP", filter_type = "STARTS_WITH", filter_value = "app-payroll-" },
      ]

      group_names   = ["app-payroll-users", "app-payroll-admins"]
      signon_policy = "standard-workforce"
    }

    # The vendor's admin console. tier = "admin" makes the stack refuse the
    # plan unless the policy named here requires phishing-resistant
    # possession on every ALLOW rule; the admins group is the only
    # assignment, so the tile does not appear for anyone else.
    vendor-admin-console = {
      label                  = "Example Vendor Admin Console"
      sso_url                = "https://admin.vendor.example.com/sso/saml"
      audience               = "https://admin.vendor.example.com"
      subject_name_id_format = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

      attribute_statements = [
        { name = "email", type = "EXPRESSION", values = ["user.email"] },
      ]

      tier          = "admin"
      group_names   = ["app-vendor-admins"]
      signon_policy = "admin-phishing-resistant"
    }
  }
}
