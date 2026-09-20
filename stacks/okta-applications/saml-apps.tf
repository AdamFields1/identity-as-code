# ---------------------------------------------------------------------------
# SAML apps, after the policies they name.
#
# Every attribute is the cell's value handed to the module as is, except the
# one this stack owns: signon_policy is a key of this cell, and the module
# takes authentication_policy_id, an id. Reading the id from the policy
# module's output is what orders the two, so a policy is created before the
# app that binds it. Group assignments happen inside the module, by name.
# ---------------------------------------------------------------------------

module "saml_apps" {
  source = "../../modules/okta/app-saml"

  apps = {
    for key, a in var.saml_apps : key => {
      label                    = a.label
      sso_url                  = a.sso_url
      audience                 = a.audience
      recipient                = a.recipient
      destination              = a.destination
      subject_name_id_template = a.subject_name_id_template
      subject_name_id_format   = a.subject_name_id_format
      attribute_statements     = a.attribute_statements
      single_logout            = a.single_logout
      hide_ios                 = a.hide_ios
      hide_web                 = a.hide_web
      status                   = a.status
      authentication_policy_id = local.saml_policy_ids[key]
      tier                     = a.tier

      group_names                 = a.group_names
      group_assignment_priorities = a.group_assignment_priorities
    }
  }
}
