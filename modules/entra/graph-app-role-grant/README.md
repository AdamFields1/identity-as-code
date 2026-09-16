# modules/entra/graph-app-role-grant

Grants Microsoft Graph application permissions to one service principal, by
permission name. Built for managed identities, which have a service principal
but no application registration and therefore cannot use
`modules/entra/app-registration`'s enforced grants.

## Design notes

- **Names, not GUIDs.** Permission names are resolved against the Microsoft Graph
  service principal's `app_role_ids`; a misspelled or non-existent name fails the
  plan with the name in the message. The principal is given by object ID (from the
  module that created the identity) or by display name, never by both.
- **Admin consent as code.** Each `azuread_app_role_assignment` is the consented
  grant. Removing a name from `app_role_names` revokes it on the next apply, so
  what an automation identity may do is reviewed like any other change.
- **Why not `app-registration`?** That module validates every enforced grant
  against the registration's `required_resource_access` so manifest and consent
  never disagree. A managed identity has no manifest, so there is nothing to
  validate against and no registration to create; this module is the grant alone.

## Mail.Send needs a second control outside Terraform

`Mail.Send` as an application permission lets the principal send as any mailbox
in the tenant. Pair it with an Exchange Online application access policy that
restricts the principal to the shared mailbox the runbooks send from:

```powershell
New-ApplicationAccessPolicy -AppId <identity client id> `
  -PolicyScopeGroupId <mail-enabled security group containing the sender mailbox> `
  -AccessRight RestrictAccess -Description "identity automation runbooks: send only as iam-noreply"
```

That policy is an Exchange object with no Terraform resource. It is applied once
by whoever administers Exchange, and its presence is checked with
`Test-ApplicationAccessPolicy`. This module grants the permission; the policy
bounds it; the README of the stack that uses this module says so again.

## Usage

```hcl
module "graph_grants" {
  source = "../../modules/entra/graph-app-role-grant"

  principal_object_id = module.automation_account.identity_principal_id

  app_role_names = [
    "Application.Read.All",
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Mail.Send",
    "Directory.Read.All",
    "AuditLog.Read.All",
  ]
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `principal_object_id` | `string` | `null` | Service principal object ID. One of the two. |
| `principal_display_name` | `string` | `null` | Service principal display name. One of the two. |
| `app_role_names` | `list(string)` | n/a | Graph application permission names. |

## Outputs

| Name | Description |
|------|-------------|
| `assignment_ids` | Map of permission name to assignment ID. |
| `principal_object_id` | The principal granted to. |
| `graph_service_principal_object_id` | Microsoft Graph's service principal in this tenant. |

## Import

```hcl
import {
  to = module.graph_grants.azuread_app_role_assignment.this["Mail.Send"]
  id = "/servicePrincipals/00000000-0000-0000-0000-000000000000/appRoleAssignedTo/00000000-0000-0000-0000-000000000000"
}
```

The first GUID is the Microsoft Graph service principal's object ID, the second is
the assignment ID as listed by `GET /servicePrincipals/{graph sp id}/appRoleAssignedTo`.
