# ---------------------------------------------------------------------------
# Identity providers first. Every routing rule references their ids.
#
# Every attribute is the cell's value handed to the module as is, except the
# three this stack owns: provisioning.groups_filter,
# provisioning.groups_assignment, and account_link.group_include are group
# NAMES in the cell, and the module takes ids. Reading the ids from the group
# lookups in main.tf is what makes a missing group fail the plan with its name.
# The signing certificates pass through as the PEM text the cell read with
# file(); the module strips the armor and creates one key per entry.
# ---------------------------------------------------------------------------

module "identity_providers" {
  source = "../../modules/okta/idp-saml"

  identity_providers = {
    for key, p in var.identity_providers : key => {
      name                     = p.name
      status                   = p.status
      issuer                   = p.issuer
      issuer_mode              = p.issuer_mode
      sso_url                  = p.sso_url
      sso_binding              = p.sso_binding
      sso_destination          = p.sso_destination
      acs_type                 = p.acs_type
      signing_certificates     = p.signing_certificates
      active_certificate       = p.active_certificate
      response_signature_scope = p.response_signature_scope
      max_clock_skew           = p.max_clock_skew
      honor_persistent_name_id = p.honor_persistent_name_id

      subject = p.subject

      provisioning = {
        action               = p.provisioning.action
        deprovisioned_action = p.provisioning.deprovisioned_action
        suspended_action     = p.provisioning.suspended_action
        profile_master       = p.provisioning.profile_master
        groups_action        = p.provisioning.groups_action
        groups_attribute     = p.provisioning.groups_attribute
        groups_filter        = [for name in p.provisioning.groups_filter : local.group_ids[name]]
        groups_assignment    = [for name in p.provisioning.groups_assignment : local.group_ids[name]]
      }

      account_link = {
        action        = p.account_link.action
        group_include = [for name in p.account_link.group_include : local.group_ids[name]]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# The ACS URL of each trust, the value the other side posts the SAML response
# to. Okta does not export it, but its form is documented: for acs_type
# INSTANCE it is https://<org>/sso/saml2/<identity provider id> and for ORG it
# is https://<org>/sso/saml2, shared by every trust in the org
# (https://developer.okta.com/docs/guides/add-an-external-idp/saml2/main/,
# "the string after the last slash is the Identity Provider's id"). The host
# is the org URL built from okta_org_name and okta_base_url; a trust with
# issuer_mode CUSTOM_URL is published on the custom domain instead, which
# this stack does not know, and the output description says so.
# ---------------------------------------------------------------------------

locals {
  acs_urls = {
    for key, p in module.identity_providers.identity_providers :
    key => p.acs_type == "INSTANCE" ? "${local.org_url}/sso/saml2/${p.id}" : "${local.org_url}/sso/saml2"
  }
}
