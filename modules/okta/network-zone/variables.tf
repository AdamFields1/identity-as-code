variable "zones" {
  description = <<-EOT
    Network zones to manage, keyed by a stable logical name (for example "corp-egress").
    The key becomes part of the Terraform resource address, so renaming a key moves the
    resource in state. Change the display name with the "name" attribute instead.

    type   : "IP" for gateway/proxy CIDR zones, "DYNAMIC" for geolocation/ASN zones.
    usage  : "POLICY" (referenced by policy rules) or "BLOCKLIST" (org-wide deny).
    status : "ACTIVE" or "INACTIVE".

    IP zones use gateways and proxies. Each entry is a single IP, a CIDR, or a range
    written as "start-end". DYNAMIC zones use dynamic_locations (ISO country or
    country-region codes such as "US" or "US-CA"), asns, and dynamic_proxy_type.
  EOT

  type = map(object({
    name               = string
    type               = string
    usage              = optional(string, "POLICY")
    status             = optional(string, "ACTIVE")
    gateways           = optional(list(string), [])
    proxies            = optional(list(string), [])
    dynamic_locations  = optional(list(string), [])
    asns               = optional(list(string), [])
    dynamic_proxy_type = optional(string)
  }))

  validation {
    condition     = alltrue([for z in var.zones : contains(["IP", "DYNAMIC"], z.type)])
    error_message = "Each zone type must be \"IP\" or \"DYNAMIC\"."
  }

  validation {
    condition     = alltrue([for z in var.zones : contains(["POLICY", "BLOCKLIST"], z.usage)])
    error_message = "Each zone usage must be \"POLICY\" or \"BLOCKLIST\"."
  }

  validation {
    condition     = alltrue([for z in var.zones : contains(["ACTIVE", "INACTIVE"], z.status)])
    error_message = "Each zone status must be \"ACTIVE\" or \"INACTIVE\"."
  }

  validation {
    condition = alltrue([
      for z in var.zones :
      z.type != "IP" || (length(z.gateways) + length(z.proxies)) > 0
    ])
    error_message = "IP zones must define at least one gateway or proxy entry."
  }

  validation {
    condition = alltrue([
      for z in var.zones :
      z.type != "DYNAMIC" || (length(z.dynamic_locations) + length(z.asns)) > 0 || z.dynamic_proxy_type != null
    ])
    error_message = "DYNAMIC zones must define at least one location, ASN, or a dynamic_proxy_type."
  }

  validation {
    condition = alltrue(flatten([
      for z in var.zones : [
        for entry in concat(z.gateways, z.proxies) :
        can(regex("^(\\d{1,3}\\.){3}\\d{1,3}(/\\d{1,2}|-(\\d{1,3}\\.){3}\\d{1,3})?$", entry))
      ]
    ]))
    error_message = "Gateway and proxy entries must be an IPv4 address, a CIDR (10.0.0.0/8), or a range (10.0.0.1-10.0.0.9)."
  }

  validation {
    condition = alltrue([
      for z in var.zones :
      z.dynamic_proxy_type == null || contains(["Any", "TorAnonymizer", "NotTorAnonymizer"], z.dynamic_proxy_type)
    ])
    error_message = "dynamic_proxy_type must be one of \"Any\", \"TorAnonymizer\", or \"NotTorAnonymizer\" when set."
  }
}
