# fixture fragment of ./terragrunt.hcl, included there as "signon_policies":
# one inputs attribute holding signon_policies and nothing else.

inputs = {
  signon_policies = {
    standard-workforce = {
      name = "Standard workforce (dev)"
      rules = {
        corp-zones = {
          name               = "Corporate egress or VPN"
          access             = "ALLOW"
          factor_mode        = "2FA"
          network_zone_names = ["Corporate egress"]
        }
      }
    }
  }
}
