# Entra corp tenant: the enterprise applications cell's SAML apps.
#
# A fragment of ./terragrunt.hcl, included there as "saml_apps": one inputs
# attribute holding saml_apps and nothing else. Values only, as the cell is;
# the header comment in terragrunt.hcl describes the whole cell.
#
# SAML service providers, gallery or custom. An entry is what the vendor's
# onboarding guide asks for: the entity ID it expects as the audience, the
# assertion consumer service URL, the sign-on URL the My Apps tile starts
# from, how the subject is named, the attributes the assertion carries, who is
# mailed before the signing certificate expires, and which groups may open the
# app through which app role. Assignment required, SAML as the sign-on mode, a
# signing key Entra generates, the claims mapping policy the module renders,
# https-only endpoints with no wildcard, and the group claim limited to the
# groups assigned to the application are fixed by the module and not on the
# menu. After apply, the stack's vendor_onboarding output holds the issuer,
# the login and logout URLs, the metadata URL, and the signing certificate
# thumbprint the vendor configures on their side.

inputs = {
  saml_apps = {
    # Google Workspace, from the gallery. The entity ID is the bare
    # identifier the template requires, and the ACS and sign-on URLs carry the
    # Workspace domain as the vendor's guide shows them. The template
    # publishes the User role; the module refuses a role the template does
    # not carry.
    google-workspace = {
      display_name                  = "Google Workspace"
      gallery_template_display_name = "Google Cloud / G Suite Connector by Microsoft"
      identifier_uris               = ["google.com"]
      reply_urls                    = ["https://www.google.com/a/example.com/acs"]
      sign_on_url                   = "https://www.google.com/a/example.com/ServiceLogin?continue=https://mail.google.com"
      notification_email_addresses  = ["iam-alerts@example.com"]

      signing_certificate = { display_name = "Google Workspace SAML signing" }
      name_id             = { source = "mail", format = "emailAddress" }

      app_roles_to_groups = {
        User = ["app-google-workspace-users"]
      }

      # provisioning stays unset: the Google connector is authorised by an
      # OAuth consent in the portal, which Terraform cannot perform. The
      # header of terragrunt.hcl lists the one console step.
    }

    # The payroll vendor, as a custom application. The same vendor the Okta
    # catalog onboards, with the same entity ID, ACS URL, subject and two
    # groups; the attributes are this provider's rendering of the vendor's
    # guide (Okta sends name from displayName, Entra sends firstName and
    # lastName). The module creates the User and Admin app roles on the
    # application and assigns the groups through them.
    # The groups claim is limited to the groups assigned to the application,
    # so the vendor never sees the rest of the directory.
    example-payroll = {
      display_name                 = "Example Payroll"
      identifier_uris              = ["https://payroll.example.com"]
      reply_urls                   = ["https://payroll.example.com/saml/acs"]
      sign_on_url                  = "https://payroll.example.com/login"
      notification_email_addresses = ["iam-alerts@example.com"]

      signing_certificate = { display_name = "Example Payroll SAML signing" }
      name_id             = { source = "mail", format = "emailAddress" }

      claims = [
        { name = "email", source = "mail" },
        { name = "firstName", source = "givenName" },
        { name = "lastName", source = "surname" },
        { name = "groups", source = "groups" },
      ]

      app_roles_to_groups = {
        User  = ["app-payroll-users"]
        Admin = ["app-payroll-admins"]
      }
    }

    # The Okta org, as a custom application: the other side of the trust the
    # okta-federation cells build (tenants/okta/<env>/okta-federation/). Here
    # this tenant is the identity provider and Okta is the service provider,
    # so the entity ID and the ACS URL are Okta's: the audience suffix
    # (spexampleplaceholder) and the identity provider id (0oa...) are
    # minted by Okta and appear only in the identity_provider_onboarding
    # output after the first Okta apply. The values below are the
    # provisional ones the stack README's "Bootstrapping the trust in two
    # applies" describes; the second Entra apply replaces them with the
    # output's audience and acs_url. The three values that cross the other
    # way (this tenant's issuer and sign-on URL, and this application's
    # signing certificate, downloaded in Base64 form) are what the Okta cell
    # carries. The subject is the mail address in the emailAddress format,
    # which the Okta side matches on email, and no other claim is needed:
    # Okta reads the NameID and nothing else. Everyone in the workforce group
    # is assigned through the User role; provisioning stays unset, because
    # the directory of record provisions Okta and the Okta cell keeps
    # just-in-time creation off.
    okta-workforce = {
      display_name                 = "Okta (workforce federation)"
      identifier_uris              = ["https://www.okta.com/saml2/service-provider/spexampleplaceholder"]
      reply_urls                   = ["https://example-org.okta.com/sso/saml2/0oa00000000000000000"]
      sign_on_url                  = "https://example-org.okta.com"
      notification_email_addresses = ["iam-alerts@example.com"]

      signing_certificate = { display_name = "Okta federation signing" }
      name_id             = { source = "mail", format = "emailAddress" }

      app_roles_to_groups = {
        User = ["all-workforce"]
      }
    }
  }
}
