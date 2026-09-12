# modules/okta/network-zone

Manages a set of Okta network zones from a single map. Zones are the foundation for
every "trusted network" decision in sign-on, MFA, and password policies, so this module
is applied first and its `zone_ids` output feeds the policy modules.

## Design notes

- The map key is a stable logical name (`corp-egress`, `vpn`, `deny-tor`). It is part
  of the Terraform address, so it should never change once applied. The display name
  in Okta is the `name` attribute and can change freely.
- `for_each` over a map, never `count`. Removing one zone does not shift the others.
- IP-only and DYNAMIC-only attributes are sent as `null` when they do not apply to the
  zone type, which avoids perpetual diffs.
- Validation rejects malformed CIDRs and ranges before a plan ever reaches the API.

## Usage

```hcl
module "network_zones" {
  source = "../../modules/okta/network-zone"

  zones = {
    corp-egress = {
      name     = "Corporate Egress"
      type     = "IP"
      usage    = "POLICY"
      gateways = ["203.0.113.0/24", "198.51.100.10-198.51.100.20"]
    }

    deny-tor = {
      name               = "Block Tor exit nodes"
      type               = "DYNAMIC"
      usage              = "BLOCKLIST"
      dynamic_proxy_type = "TorAnonymizer"
    }

    allowed-countries = {
      name              = "Allowed countries"
      type              = "DYNAMIC"
      dynamic_locations = ["US", "CA"]
    }
  }
}

output "corp_zone_id" {
  value = module.network_zones.zone_ids["corp-egress"]
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `zones` | `map(object)` | Zones keyed by logical name. See `variables.tf` for the object shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `zone_ids` | Map of logical key to zone ID. |
| `zones` | Map of logical key to `{ id, name, type, usage, status }`. |

## Importing existing zones

```hcl
import {
  to = module.network_zones.okta_network_zone.this["corp-egress"]
  id = "nzo0000000000000000"
}
```

The `scripts/Import-OktaPolicies.ps1` helper at the repo root generates these blocks
from a live tenant.
