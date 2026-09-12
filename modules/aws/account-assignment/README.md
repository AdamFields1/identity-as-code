# modules/aws/account-assignment

Manages IAM Identity Center account assignments from a list of group names. The
group name carries the whole assignment, so the module takes nothing else except
the permission sets it is allowed to reference.

## The naming convention

```
AWS-<PARTITION>-<accountId>-<PermissionSetName>

AWS-COM-111111111111-PlatformAdmin
AWS-COM-222222222222-PowerUser
AWS-GOV-333333333333-ReadOnly
```

| Field | Values | Used for |
|-------|--------|----------|
| `PARTITION` | `COM` (arn:aws) or `GOV` (arn:aws-us-gov) | Which Identity Center instance the group belongs to. A cell rejects groups for the other partition. |
| `accountId` | 12 digits | The assignment target. |
| `PermissionSetName` | letters and digits | The permission set, which must be defined in the same stack. |

Regex, enforced by a validation block: `^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$`.

The convention is shared with the Entra side. An Entra security group with this
name is assigned to the Identity Center gallery application for its partition
(`modules/entra/aws-identity-center-app`), SCIM provisions it into that
instance's identity store under the same display name, and this module assigns
it. See [ADR 0008](../../../docs/adr/0008-entra-id-as-the-identity-source-for-aws.md).

## Why a name-carried model

- **The group is self-describing.** An access reviewer who sees
  `AWS-COM-111111111111-ReadOnly` in an Entra access review knows exactly what
  membership grants, in which account, without opening the AWS console or this
  repository.
- **Provisioning and assignment derive from one artifact.** The group exists in
  the identity store because it is assigned to the Entra application; it has an
  assignment because it exists. There is no second list of accounts and permission
  sets that can drift from the first.
- **The name is a checked reference.** The permission set in the name must be a
  key of `permission_set_arns_by_name`, or the plan fails with the group name and
  the list of managed sets. The partition token must match the partition the
  provider is talking to, read from `data.aws_partition`, or the plan fails saying
  which cell the group belongs in.
- **A key rename is a real change.** The map key is the group name, so renaming a
  group (which is a new group in Entra, and therefore a new group in the identity
  store) is visibly a destroy-and-create of the assignment.

## Design notes

- **Groups only.** `principal_type` is fixed to `GROUP` and there is no user
  input. A person-to-permission edge belongs in the directory of record, where it
  is reviewed, where it is subject to PIM for groups when just-in-time access is
  wanted, and where it disappears when the person leaves.
- **Groups are resolved by display name in the identity store.**
  `aws_identitystore_group` with an `alternate_identifier` on `DisplayName` is a
  server-side lookup. A group SCIM has not provisioned yet fails the plan with its
  name in the error rather than creating an assignment for nobody.
- **The account ID is trusted from the name.** There is no AWS Organizations
  lookup; the module does not need `organizations:ListAccounts` and runs unchanged
  from the Identity Center delegated administrator account. A mistyped account ID
  fails at apply, when Identity Center refuses to provision into an account that is
  not in the organization.

## Usage

```hcl
module "account_assignments" {
  source = "../../modules/aws/account-assignment"

  permission_set_arns_by_name = module.permission_sets.permission_set_arns_by_name

  group_display_names = [
    "AWS-COM-111111111111-PlatformAdmin",
    "AWS-COM-111111111111-ReadOnly",
    "AWS-COM-222222222222-PowerUser",
  ]
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `group_display_names` | `list(string)` | n/a | Convention-named groups. See `variables.tf` for the validation rules. |
| `permission_set_arns_by_name` | `map(string)` | n/a | Permission set name to ARN, from the permission-set module. |

## Outputs

| Name | Description |
|------|-------------|
| `assignments` | Map of group name to `{ partition_token, account_id, permission_set_name, permission_set_arn, group_id }`. |
| `assignment_ids` | Map of group name to assignment resource ID. |
| `group_ids` | Map of group name to identity store group ID. |
| `partition_token` | `COM` or `GOV`, as discovered. |

## Import

The import ID is the principal ID, principal type, target ID, target type,
permission set ARN, and instance ARN, comma separated.

```hcl
import {
  to = module.account_assignments.aws_ssoadmin_account_assignment.this["AWS-COM-111111111111-ReadOnly"]
  id = "00000000-0000-0000-0000-000000000000,GROUP,111111111111,AWS_ACCOUNT,arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000000,arn:aws:sso:::instance/ssoins-0000000000000000"
}
```
