output "apps" {
  description = "Map of logical key to { id, label, client_id, type, status }. The client secret is never an output and, with omit_secret fixed true, never in state."
  value = {
    for k, a in okta_app_oauth.this : k => {
      id        = a.id
      label     = a.label
      client_id = a.client_id
      type      = a.type
      status    = a.status
    }
  }
}

output "client_ids_by_label" {
  description = "Map of app label to OAuth client ID, for callers that reference apps by label."
  value       = { for k, a in okta_app_oauth.this : a.label => a.client_id }
}
