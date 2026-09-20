output "signon_policy_ids" {
  description = "Map of policy key to app sign-on policy ID, the id each app in this cell was bound with."
  value       = module.signon_policies.policy_ids
}

output "saml_vendor_onboarding" {
  description = "Map of SAML app key to { entity_id, sso_url, metadata_url, certificate }: the four values a service provider asks for. Nothing here is secret; the certificate is the public half of the signing key."
  value       = module.saml_apps.vendor_onboarding
}

output "saml_app_ids" {
  description = "Map of SAML app key to Okta app ID."
  value       = { for key, a in module.saml_apps.apps : key => a.id }

  # The admin-tier check. phishing_resistant_only is computed by the policy
  # module from the values, so this runs at plan time and names the apps. It is
  # a precondition rather than a variable validation because it reads a module
  # output: the policy module owns what "phishing resistant" means, and the
  # stack only asks it. The catch-all is DENY, so the answer is about the whole
  # policy and not just the rules the cell wrote.
  precondition {
    condition     = length(local.saml_admin_violations) == 0
    error_message = "SAML apps with tier = \"admin\" must name a signon_policy whose ALLOW rules all require constraints.possession.phishing_resistant = \"REQUIRED\": ${join(", ", local.saml_admin_violations)}. An admin console behind a policy that accepts a phishable factor is the account takeover path this catalog exists to close. Point the app at a phishing-resistant policy, or add the constraint to every ALLOW rule of the one it names."
  }
}

output "oauth_client_ids" {
  description = "Map of OIDC app key to OAuth client ID, what a developer configures their client with. The client secret is never an output and, with omit_secret fixed true in the module, never in state."
  value       = { for key, a in module.oauth_apps.apps : key => a.client_id }
}

output "oauth_app_ids" {
  description = "Map of OIDC app key to Okta app ID."
  value       = { for key, a in module.oauth_apps.apps : key => a.id }

  # Same check as saml_app_ids, for the OIDC map.
  precondition {
    condition     = length(local.oauth_admin_violations) == 0
    error_message = "OIDC apps with tier = \"admin\" must name a signon_policy whose ALLOW rules all require constraints.possession.phishing_resistant = \"REQUIRED\": ${join(", ", local.oauth_admin_violations)}. An admin app behind a policy that accepts a phishable factor is the account takeover path this catalog exists to close. Point the app at a phishing-resistant policy, or add the constraint to every ALLOW rule of the one it names."
  }
}
