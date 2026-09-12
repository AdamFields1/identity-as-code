output "zone_ids" {
  description = "Map of logical zone key to Okta network zone ID. Use these IDs in policy rule network conditions."
  value       = { for k, z in okta_network_zone.this : k => z.id }
}

output "zones" {
  description = "Map of logical zone key to a summary object (id, name, type, usage, status)."
  value = {
    for k, z in okta_network_zone.this : k => {
      id     = z.id
      name   = z.name
      type   = z.type
      usage  = z.usage
      status = z.status
    }
  }
}
