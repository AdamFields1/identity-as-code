# Entra corp tenant cell: application registrations.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Application onboarding is confined to corp. The subsidiary has no
# entra-app-registrations cell; it consumes corp applications as a multi-tenant
# sign-in audience rather than registering its own.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/entra-app-registrations/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-app-registrations"
}

inputs = {
  # -------------------------------------------------------------------------
  # Access groups. Created with the applications they govern. Membership of
  # payroll-api-users is nested from an existing directory group; hr-portal-users
  # lists nobody, so the application owner manages membership in the portal.
  # -------------------------------------------------------------------------
  security_groups = {
    payroll-api-users = {
      display_name  = "APP Payroll API Users"
      description   = "Users of the Payroll API. Nested from Finance Staff."
      owners        = ["payroll.owner@corp.example.com"]
      member_groups = ["Finance Staff"]
    }

    hr-portal-users = {
      display_name = "APP HR Portal Users"
      description  = "Users of the HR Portal. Membership managed by the application owner."
      owners       = ["hr.owner@corp.example.com"]
    }
  }

  # -------------------------------------------------------------------------
  # Application registrations. Permissions are names. Credentials are federated.
  # There is no client secret anywhere in this file, and the stack cannot make one.
  # -------------------------------------------------------------------------
  applications = {
    payroll-api = {
      display_name    = "Payroll API"
      owners          = ["payroll.owner@corp.example.com"]
      identifier_uris = ["api://payroll-api"]

      required_resource_access = {
        MicrosoftGraph = {
          application = ["User.Read.All"]
          delegated   = ["User.Read"]
        }
      }

      # Admin consent as code. Removing a name here revokes the grant.
      enforced_graph_app_roles = ["User.Read.All"]

      federated_credentials = {
        github-prod = {
          display_name = "GitHub Actions (prod)"
          subject      = "repo:example-org/payroll-api:environment:prod"
        }
      }
    }

    hr-portal = {
      display_name      = "HR Portal"
      owners            = ["hr.owner@corp.example.com"]
      web_redirect_uris = ["https://hr-portal.corp.example.com/signin-oidc"]
      web_logout_url    = "https://hr-portal.corp.example.com/signout-oidc"
      tags              = ["hr", "web"]

      required_resource_access = {
        MicrosoftGraph = {
          delegated = ["User.Read", "openid", "profile", "offline_access"]
        }
      }
    }

    # The identity this repository's own pipeline uses against corp. It is
    # bootstrapped by hand once, then adopted here with imports.tf so that its
    # permissions are reviewed like any other change. The federated credential
    # subject pins it to one repository and one GitHub environment.
    identity-as-code-deployer = {
      display_name = "identity-as-code deployer (corp)"
      owners       = ["iam.lead@corp.example.com"]

      required_resource_access = {
        MicrosoftGraph = {
          application = [
            "Application.ReadWrite.All",
            "Group.ReadWrite.All",
            "Policy.ReadWrite.ConditionalAccess",
            "Policy.Read.All",
            "RoleManagement.ReadWrite.Directory",
            "PrivilegedAccess.ReadWrite.AzureADGroup",
            "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup",
            "RoleManagementPolicy.ReadWrite.AzureADGroup",
            "User.Read.All",
          ]
        }
      }

      enforced_graph_app_roles = [
        "Application.ReadWrite.All",
        "Group.ReadWrite.All",
        "Policy.ReadWrite.ConditionalAccess",
        "Policy.Read.All",
        "RoleManagement.ReadWrite.Directory",
        "PrivilegedAccess.ReadWrite.AzureADGroup",
        "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup",
        "RoleManagementPolicy.ReadWrite.AzureADGroup",
        "User.Read.All",
      ]

      federated_credentials = {
        github-corp-apply = {
          display_name = "GitHub Actions (corp-apply environment)"
          subject      = "repo:example-org/identity-as-code:environment:corp-apply"
        }
        github-corp-plan = {
          display_name = "GitHub Actions (corp-plan environment)"
          subject      = "repo:example-org/identity-as-code:environment:corp-plan"
        }
      }

      service_principal = {
        app_role_assignment_required = false
      }
    }
  }
}
