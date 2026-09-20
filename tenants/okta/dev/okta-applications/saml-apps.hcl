# Okta dev tenant: the application catalog cell's SAML apps.
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
# and signing certificate the vendor configures on their sandbox.

inputs = {
  saml_apps = {
    # The payroll vendor's sandbox. Same entry as prod with the dev host, so
    # the attribute and group wiring is proven here before the prod cell
    # points at the vendor's live tenant.
    payroll = {
      label                  = "Example Payroll"
      sso_url                = "https://payroll.dev.example.com/saml/acs"
      audience               = "https://payroll.dev.example.com"
      subject_name_id_format = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

      attribute_statements = [
        { name = "email", type = "EXPRESSION", values = ["user.email"] },
        { name = "name", type = "EXPRESSION", values = ["user.displayName"] },
        { name = "groups", type = "GROUP", filter_type = "STARTS_WITH", filter_value = "app-payroll-" },
      ]

      group_names   = ["app-payroll-users", "app-payroll-admins"]
      signon_policy = "standard-workforce"
    }
  }
}
