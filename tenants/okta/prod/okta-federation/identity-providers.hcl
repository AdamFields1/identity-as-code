# Okta prod tenant: the federation cell's identity providers.
#
# A fragment of ./terragrunt.hcl, included there as "identity_providers": one
# inputs attribute holding identity_providers and nothing else. Values only,
# as the cell is; the header comment in terragrunt.hcl describes the whole
# cell.
#
# Upstream SAML 2.0 identity providers. An entry is what the other side's
# federation metadata publishes: the issuer, the single sign-on endpoint,
# and the signing certificate, read with file() from the .cer beside this
# cell; plus how the asserted subject is matched to an Okta user, whether
# Okta creates users the identity provider asserts, and which certificate
# entry is trusted now. Signed AuthnRequests (SHA-256), SHA-256 on the
# response signature, https-only endpoints with no wildcard, and SAML2 as
# the only routing target are fixed by the module and not on the menu.
# After apply, the stack's identity_provider_onboarding output holds the
# audience and the ACS URL the Entra side sets as the okta-workforce
# application's identifier and reply URL.

inputs = {
  identity_providers = {
    # The corp Entra tenant. The issuer and the sign-on URL are the tenant's,
    # in the forms Entra publishes them (https://sts.windows.net/<tenant id>/
    # and https://login.microsoftonline.com/<tenant id>/saml2, the latter the
    # form the Entra module outputs). The certificate is the okta-workforce
    # application's SAML signing certificate, downloaded in Base64 form to
    # entra-signing-2026.cer; the file here is a placeholder, and its header
    # says what replaces it. Entra signs the assertion by default, so the
    # response signature scope is ASSERTION. Subjects match on email in the
    # emailAddress format and provisioning stays DISABLED: the directory of
    # record provisions users, the same line okta-config draws.
    #
    # Account linking is AUTO, and it is fenced on both sides. The subject
    # filter is the pattern an asserted username must match, so this trust can
    # assert nothing outside the corp domain, and group_include is the group
    # whose existing members may be linked, the same all-workforce group the
    # Entra application assigns. Without those two, an assertion for any
    # address at all would be linked automatically to whichever Okta user
    # matched it on email, an Okta administrator included; they are the only
    # account-link guards the resource offers.
    entra = {
      name        = "Entra ID (corp tenant)"
      issuer      = "https://sts.windows.net/11111111-1111-1111-1111-111111111111/"
      sso_url     = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/saml2"
      sso_binding = "HTTP-POST"

      signing_certificates = {
        "2026" = file("${get_terragrunt_dir()}/entra-signing-2026.cer")
      }
      active_certificate = "2026"

      response_signature_scope = "ASSERTION"

      subject = {
        match_type = "EMAIL"
        format     = ["urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"]
        filter     = "(\\S+@example\\.com)"
      }

      provisioning = { action = "DISABLED" }

      account_link = {
        action        = "AUTO"
        group_include = ["all-workforce"]
      }
    }
  }
}
