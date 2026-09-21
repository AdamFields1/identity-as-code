# ---------------------------------------------------------------------------
# SAML apps. One module call with the cell's map.
#
# Every attribute is the cell's value handed to the module as is, including
# provisioning (template_id and base_address). The one thing the stack adds
# is the token map from TF_VAR_provisioning_secret_tokens, passed straight to
# the module's own sensitive input beside the map, so neither the cell nor
# the map ever holds the token. Templates, groups and gallery app roles are
# resolved inside the module, by name.
# ---------------------------------------------------------------------------

module "saml_apps" {
  source = "../../modules/entra/saml-enterprise-app"

  saml_apps = {
    for key, a in var.saml_apps : key => {
      display_name                  = a.display_name
      gallery_template_display_name = a.gallery_template_display_name
      identifier_uris               = a.identifier_uris
      reply_urls                    = a.reply_urls
      sign_on_url                   = a.sign_on_url
      logout_url                    = a.logout_url
      relay_state                   = a.relay_state
      notification_email_addresses  = a.notification_email_addresses
      signing_certificate           = a.signing_certificate
      name_id                       = a.name_id
      claims                        = a.claims
      app_roles_to_groups           = a.app_roles_to_groups
      account_enabled               = a.account_enabled
      provisioning                  = a.provisioning
    }
  }

  provisioning_secret_tokens = var.provisioning_secret_tokens
}
