# ADR 0009: Commercial and GovCloud are cells of one stack, and the partition is discovered

Status: accepted
Date: 2026-09-12

## Context

AWS GovCloud (US) is a separate partition. Its ARNs start `arn:aws-us-gov`, its
accounts belong to a separate organization, its credentials do not work against
commercial endpoints, its IAM Identity Center is a separate instance with a
separate identity store, and an S3 bucket in it cannot be reached with a
commercial identity. From Terraform's point of view it is a different cloud
that happens to have the same provider and the same resource types.

The organisation runs Identity Center in both. The permission sets are largely
the same idea (an administrator set, a read-only set), the session durations and
the account list differ, and the Entra tenant that is the identity source is the
same for both (ADR 0008).

Three shapes were considered.

**One stack, one cell, two providers.** A single root module with `provider
"aws" { alias = "govcloud" }` and every resource duplicated with a provider
argument. One state file for both partitions means one set of credentials must
reach both, which cannot be done with a single OIDC role, and a GovCloud outage
blocks a commercial change.

**Two stacks.** `stacks/aws-identity-center` and
`stacks/aws-identity-center-govcloud`, with the partition literal baked into
each. Every managed policy ARN, every README, and every fix would exist twice
and diverge.

**One stack, one cell per partition, partition discovered at plan time.** The
same code runs in both cells; the only thing a cell says is which region, and
the modules read the partition from `data.aws_partition` and build ARNs from it.

## Decision

**One stack, two cells.** `tenants/aws/commercial/aws-identity-center` and
`tenants/aws/govcloud/aws-identity-center` both point at
`stacks/aws-identity-center`. A cell holds `region`, the permission set
definitions, and the list of convention-named groups. It contains no partition
literal, no ARN, and no account ID other than the ones carried in group names.

**The partition is discovered, never typed.** `modules/aws/permission-set` turns
managed policy names into ARNs with `arn:${data.aws_partition.current.partition}:iam::aws:policy/`,
so `AdministratorAccess` in the GovCloud cell becomes
`arn:aws-us-gov:iam::aws:policy/AdministratorAccess` and in the commercial cell
`arn:aws:iam::aws:policy/AdministratorAccess`. `modules/aws/account-assignment`
maps the discovered partition to the naming convention's token (`aws` to `COM`,
`aws-us-gov` to `GOV`) and rejects any group whose token does not match. A
GovCloud cell that is accidentally planned against commercial credentials fails
on every assignment with a message saying which partition each side is in,
before anything is written.

**Everything partition-specific lives in the environment, per cell.**
`tenants/aws/root.hcl` reads `TG_AWS_STATE_BUCKET`, `TG_AWS_STATE_REGION`, and
`TG_AWS_LOCK_TABLE` from the environment, and the AWS workflows set those at job
level from GitHub environment variables: `commercial-plan` and `commercial`
point at a commercial bucket and commercial OIDC roles, `govcloud-plan` and
`govcloud-apply` at a GovCloud bucket and GovCloud roles. Repository-level
variables are the commercial defaults; the GovCloud environments override every
one of them. Nothing in HCL knows there are two buckets.

**The state key is the same scheme in both.** `aws/${path_relative_to_include()}/terraform.tfstate`
gives `aws/commercial/aws-identity-center/terraform.tfstate` in one bucket and
`aws/govcloud/aws-identity-center/terraform.tfstate` in the other. The paths do
not collide even though the buckets are different, so moving both to one bucket
in a future single-partition world would need no key change.

**GovCloud is the gated partition.** `aws-release` applies commercial, saves a
merge-time plan for GovCloud, waits at the `govcloud` environment gate, and
applies that exact plan. The reasoning is the same as for prod and the
subsidiary: the higher-assurance environment gets the plan a human approved,
and a stale plan is refused rather than re-taken.

## Consequences

- `diff tenants/aws/commercial/aws-identity-center/terragrunt.hcl tenants/aws/govcloud/aws-identity-center/terragrunt.hcl`
  is the complete answer to "what is stricter in GovCloud": PT1H everywhere,
  fewer permission sets, fewer accounts, and `AWS-GOV-` in every group name.
- Adding a partition (a third instance, or China) is a new cell directory plus
  a new token in the account-assignment module's partition map and in the
  naming convention regex. The stack does not change.
- Two state buckets and two sets of OIDC roles are a real bootstrap cost. It is
  the cost of the partitions being separate, not of this design; the design just
  refuses to hide it.
- The Entra side does not care. One tenant feeds both instances; the gallery
  application for GovCloud points at GovCloud SAML and SCIM endpoints, and the
  partition token in each group name says which application it is assigned to.
  Nothing about the Entra tenant is partition-specific (ADR 0008).
- `data.aws_partition` only recognises `aws` and `aws-us-gov` in the
  account-assignment module's token map. Any other partition fails the plan by
  design rather than being guessed.
