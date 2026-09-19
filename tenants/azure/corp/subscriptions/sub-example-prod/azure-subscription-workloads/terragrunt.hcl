# Azure corp tenant, subscription sub-example-prod: workloads catalog cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in a module or an app stack
# (docs/adr/0017), never in a looser entry here.
#
# The subscription is the tree, not a value: ../subscription.hcl addresses
# this cell through tenants/azure/root.hcl, and the tenant comes from
# ARM_TENANT_ID. Nothing below is a GUID or a resource ID: a resource group
# is named by its key, an identity by its key, an Entra group by display
# name, and the workspace by its name in its group.
#
# What this cell holds: one resource group; one identity the example
# application's GitHub workflow runs as, trusted from that repository's prod
# environment and nothing else; one vault the identity reads secrets from;
# one storage account with one container the identity publishes releases
# into and the engineers read. The vault and the account audit to the
# workspace ../azure-subscription-baseline creates, named here and resolved
# by name.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-prod/azure-subscription-workloads/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/azure-subscription-workloads"
}

# Ordering only. The vault and the storage account below name the Log
# Analytics workspace the baseline cell creates, resolved by name (at plan
# time once the resource group exists; on the first plan the lookup is
# deferred to apply with the group's). No outputs are read from that cell.
# This block makes `terragrunt run --all` apply the baseline first, and the
# release workflow orders the jobs the same way. See docs/adr/0005.
dependencies {
  paths = ["../azure-subscription-baseline"]
}

inputs = {
  location = "eastus"

  tags = {
    owner = "example-app"
  }

  # -------------------------------------------------------------------------
  # Resource groups. Keys are what the other maps name in resource_group_key.
  # -------------------------------------------------------------------------
  resource_groups = {
    app = {
      name        = "rg-example-app"
      delete_lock = true
    }
  }

  # -------------------------------------------------------------------------
  # Identities. The subject is built by the module from organization,
  # repository, and environment; no secret exists. Keys are what a role
  # assignment names in principal.name with type = "identity".
  # -------------------------------------------------------------------------
  identities = {
    ci-deploy = {
      name               = "id-example-app-ci"
      resource_group_key = "app"

      federated_credentials = {
        prod = {
          organization = "example-org"
          repository   = "example-app"
          environment  = "prod"
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # Key vaults. RBAC-only, purge protection, Deny firewall with public access
  # off: the module fixes that. Roles are the Key Vault data-plane menu.
  # -------------------------------------------------------------------------
  key_vaults = {
    app-secrets = {
      name               = "kv-example-app"
      resource_group_key = "app"

      log_analytics_workspace = {
        name                = "law-example-prod-activity"
        resource_group_name = "rg-example-baseline"
      }

      role_assignments = {
        ci-reads = {
          role_name   = "Key Vault Secrets User"
          principal   = { type = "identity", name = "ci-deploy" }
          description = "CI reads deployment secrets at release time."
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # Storage accounts. No shared keys, TLS 1.2, private containers, Deny
  # firewall: the module fixes that. The writer is scoped to one container;
  # the readers are a PIM-governed group named as it appears in Entra.
  # -------------------------------------------------------------------------
  storage_accounts = {
    app-artifacts = {
      name               = "stexampleapp"
      resource_group_key = "app"

      containers = {
        releases = { name = "releases" }
      }

      log_analytics_workspace = {
        name                = "law-example-prod-activity"
        resource_group_name = "rg-example-baseline"
      }

      role_assignments = {
        ci-writes-releases = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "ci-deploy" }
          container_key = "releases"
          description   = "CI publishes release artifacts and nothing else."
        }

        engineers-read = {
          role_name   = "Storage Blob Data Reader"
          principal   = { type = "group", name = "Cloud Engineers" }
          description = "Engineers read artifacts; the group is PIM-governed."
        }
      }
    }
  }
}
