# modules/aws/permission-set

Manages a map of IAM Identity Center permission sets: the set itself, its AWS
managed and customer managed policy attachments, its single inline policy, and its
optional permissions boundary. Who can use a permission set, and in which account,
is `modules/aws/account-assignment`.

## Design notes

- **Session duration is a security control.** `session_duration` bounds how long a
  console or CLI session obtained through the permission set stays valid after the
  SAML assertion that created it. Identity Center cannot revoke an issued session, so
  the duration is the only thing that limits how long a stolen token, an unlocked
  laptop, or a forgotten browser tab is useful. The module default is `PT1H`, the
  AWS minimum and default. A tenant cell raises it per permission set (`PT4H` for
  engineers in commercial, `PT1H` for everything in GovCloud) and the raise is
  visible in the diff. A validation rejects anything outside `PT1H` to `PT12H`.
- **Managed policies are names, never ARNs.** `aws_managed_policies` and the
  `aws_managed_policy` form of the boundary list policy names such as
  `ReadOnlyAccess` or `job-function/Billing`. The module builds the ARN from
  `data.aws_partition`, so the same tenant values work in commercial (`arn:aws`)
  and GovCloud (`arn:aws-us-gov`) without a partition variable anywhere.
- **Customer managed policies are references.** Identity Center attaches a customer
  managed policy by name and path, and expects a policy with that name and path to
  exist in every account the permission set is assigned to. This module does not
  create those policies; that belongs with the account baseline code.
- **One attachment resource per (set, policy).** Adding or removing a policy is a
  one-line diff on a small resource and never touches the permission set.
- **The instance is discovered.** `aws_ssoadmin_instances` returns the one instance
  in the region the provider is configured for. No instance ARN or identity store ID
  is ever typed into a tenant cell.

## Usage

```hcl
module "permission_sets" {
  source = "../../modules/aws/permission-set"

  permission_sets = {
    platform-admin = {
      name                 = "PlatformAdmin"
      description          = "Full administrative access. Short session by design."
      session_duration     = "PT1H"
      aws_managed_policies = ["AdministratorAccess"]
    }

    read-only = {
      name                 = "ReadOnly"
      description          = "Read-only access for investigation and review."
      session_duration     = "PT4H"
      aws_managed_policies = ["ReadOnlyAccess"]
      permissions_boundary = { aws_managed_policy = "ReadOnlyAccess" }
    }

    billing = {
      name                 = "Billing"
      description          = "Cost and billing console access."
      session_duration     = "PT2H"
      aws_managed_policies = ["job-function/Billing"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Deny"
          Action   = ["aws-portal:ModifyBilling", "aws-portal:ModifyPaymentMethods"]
          Resource = "*"
        }]
      })
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `permission_sets` | `map(object)` | n/a | Permission sets keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `permission_sets` | Map of key to `{ name, arn, session_duration }`. |
| `permission_set_arns_by_name` | Map of permission set name to ARN, for the account-assignment module. |
| `instance_arn` | ARN of the Identity Center instance. |
| `identity_store_id` | Identity store ID of the instance. |
| `partition` | Partition the sets were created in. |

## Import

The permission set import ID is the permission set ARN and the instance ARN,
comma separated. Attachments use the same pair with the policy identifier in
front. See the provider documentation for each resource's exact format.

```hcl
import {
  to = module.permission_sets.aws_ssoadmin_permission_set.this["read-only"]
  id = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000000,arn:aws:sso:::instance/ssoins-0000000000000000"
}
```
