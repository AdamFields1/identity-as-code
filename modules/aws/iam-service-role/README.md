# modules/aws/iam-service-role

Manages a map of IAM roles for workloads: the trust policy, the managed policy
attachments, the single inline policy, the optional permissions boundary, the
session limit, and, for roles that EC2 assumes, the instance profile. It is the
role entry of the AWS catalog stack (ADR 0017): a cell picks a trust shape and
policy names, and never writes a principal or an ARN.

## Design notes

- **Trust is a shape, not a document.** A role trusts services from an
  allowlist (`ec2`, `lambda`, `ecs-tasks`, `eks-pods`), accounts by 12-digit
  id, or one GitHub repository by named branches and environments. There is
  no input for an arbitrary principal, so a wildcard trust cannot be typed,
  and a precondition on the role checks the rendered document for a `*`
  anyway, so a future edit to the module cannot widen it quietly. EKS Pod
  Identity gets its own statement because it needs `sts:TagSession` next to
  `sts:AssumeRole`.
- **Account trust is granted to the account.** `account_principals` renders
  `arn:<partition>:iam::<id>:root`, which delegates the choice of principal
  to that account's own IAM policies, where it is reviewed by the people who
  own that account. An optional `external_id` adds the `sts:ExternalId`
  condition for third parties.
- **GitHub trust is one repository, named refs.** The subject condition is
  `StringEquals` on `repo:<owner>/<repo>:ref:refs/heads/<branch>` and
  `repo:<owner>/<repo>:environment:<name>`, one value per branch or
  environment, and the audience is pinned to `sts.amazonaws.com`. The OIDC
  provider is looked up by URL in the account and never created; a
  precondition checks it lists that audience. Provisioning the provider is
  account baseline work, like the deployment role (ADR 0017).
- **ECS task trust names the account.** The `ecs-tasks` statement carries
  `aws:SourceAccount` equal to the account the role is created in, as the
  ECS documentation recommends against the cross-service confused deputy:
  without it, any task in any account that can name the role's ARN can be
  vended its credentials. `SourceAccount` rather than the documented
  `ArnLike` on `arn:<partition>:ecs:<region>:<account>:*`, because that
  pattern carries a wildcard and the rendered-trust precondition refuses
  one; the account is exact and discovered, never typed. The other
  services on the allowlist (`ec2`, `lambda`, `eks-pods`) do not document
  the key and are left unconditioned, because a condition a service does
  not send is a role nothing can assume.
- **Administrator needs a flag, and IAM writes are administrator.**
  `AdministratorAccess` or `IAMFullAccess` in `aws_managed_policies`, or an
  inline Allow statement on `*` whose actions include `*`, `iam:*` (or any
  `iam:` pattern with a wildcard), or one of `iam:PassRole`,
  `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:CreatePolicyVersion`,
  `iam:SetDefaultPolicyVersion`, `iam:UpdateAssumeRolePolicy`, is refused
  unless the role sets `allow_admin = true`. Each of those is
  administrator by privilege escalation: attach or write a policy that
  grants everything, pass an administrator role to a service, or rewrite
  who may assume one. The flag does not make admin rare; it makes the word
  appear in the diff next to the trust that grants it, which is what a
  reviewer needs to see.
- **Managed policies are names, never ARNs.** `aws_managed_policies` and the
  `aws_managed_policy` form of the boundary take names such as
  `AmazonSSMManagedInstanceCore` or `job-function/ViewOnlyAccess`; the module
  builds the ARN from `data.aws_partition`, so the same values deploy to
  commercial and GovCloud (ADR 0009). `customer_managed_policies` are looked up
  by name and path with `data.aws_iam_policy`, so a policy that does not exist
  fails the plan with its name in the error.
- **Service principals are discovered.** They are built from the partition's
  DNS suffix (`ec2.amazonaws.com` in both supported partitions), not typed,
  and the account in the ECS condition comes from `data.aws_caller_identity`.
- **One attachment resource per (role, policy).** Adding or removing a policy
  is a one-line diff on a small resource and never touches the role.
- **Session duration is a security control.** `max_session_duration` defaults
  to 3600 seconds, the AWS minimum; a cell raises it per role and the raise is
  in the diff.
- **`force_detach_policies` is false.** A policy attached outside this module
  is drift, and drift should stop a destroy rather than be detached on the way
  out.
- **The instance profile is implied.** A role that trusts `ec2` gets a
  profile under the same name and path. A cell never mentions profiles.

## Usage

```hcl
module "service_roles" {
  source = "../../modules/aws/iam-service-role"

  roles = {
    app-server = {
      name                 = "example-app-server"
      description          = "EC2 instances of the example application."
      trust                = { services = ["ec2"] }
      aws_managed_policies = ["AmazonSSMManagedInstanceCore"]
      permissions_boundary = { customer_managed_policy = { name = "workload-boundary" } }
    }

    ci-deployer = {
      name = "example-ci-deployer"
      trust = {
        oidc_github = {
          repository   = "example-org/example-app"
          branches     = ["main"]
          environments = ["production"]
        }
      }
      customer_managed_policies = [{ name = "example-app-deploy", path = "/ci/" }]
      max_session_duration      = 3600
    }

    audit-reader = {
      name                 = "example-audit-reader"
      trust                = { account_principals = ["222222222222"], external_id = "example-audit" }
      aws_managed_policies = ["SecurityAudit", "job-function/ViewOnlyAccess"]
    }
  }
}
```

## What this module refuses

- A wildcard or ARN in `trust.account_principals`; a service not on the
  allowlist; a repository with no branch or environment; a branch or
  environment containing `*` or `?`; an `external_id` without account
  principals.
- `AdministratorAccess` or `IAMFullAccess`, or an inline Allow on `*` whose
  actions include `*`, `iam:*`, an `iam:` wildcard pattern, or
  `iam:PassRole`, `iam:AttachRolePolicy`, `iam:PutRolePolicy`,
  `iam:CreatePolicyVersion`, `iam:SetDefaultPolicyVersion`, or
  `iam:UpdateAssumeRolePolicy`, without `allow_admin = true`.
- An `ecs-tasks` trust without the account condition: the module writes
  `aws:SourceAccount` into that statement itself, so there is no input that
  can leave it out.
- A policy ARN where a policy name is expected; a boundary that sets both or
  neither of its forms; a session duration outside 3600 to 43200 seconds.
- At plan time: a customer managed policy or a GitHub OIDC provider that does
  not exist in the account, and a provider that does not list
  `sts.amazonaws.com` as an audience.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `roles` | `map(object)` | n/a | Roles keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `roles` | Map of key to `{ name, arn, unique_id, path, instance_profile_name, instance_profile_arn }`; the profile fields are null for roles without ec2 trust. |
| `role_arns_by_name` | Map of role name to ARN, for callers that reference roles by name. |
| `instance_profiles` | Map of key to `{ name, arn }` for the roles that trust ec2. |
| `github_oidc_provider_arn` | ARN of the account's GitHub OIDC provider, or null when unused. |
| `partition` | Partition the roles were created in. |

## Import

Roles import by name, inline policies by `<role name>:<policy name>`,
attachments by `<role name>/<policy ARN>`, and instance profiles by name.

```hcl
import {
  to = module.service_roles.aws_iam_role.this["app-server"]
  id = "example-app-server"
}

import {
  to = module.service_roles.aws_iam_role_policy_attachment.aws_managed["app-server/AmazonSSMManagedInstanceCore"]
  id = "example-app-server/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = module.service_roles.aws_iam_instance_profile.this["app-server"]
  id = "example-app-server"
}
```
