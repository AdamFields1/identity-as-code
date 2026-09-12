# ADR 0008: Entra ID is the identity source for AWS, and the group name is the assignment

Status: accepted
Date: 2026-09-12

## Context

AWS IAM Identity Center can hold its own users and groups, take them from a
directory through AWS Directory Service, or take them from an external identity
provider over SAML with SCIM provisioning. The organisation already has a
directory of record (the corp Entra tenant), already governs group membership
there (joiners, movers, leavers, access reviews, PIM for groups), and already
federates every other application to it. Two Identity Center instances exist,
one in the commercial partition and one in GovCloud, because a partition cannot
share an instance with another.

Three questions had to be settled: where identities come from, how a person gets
a permission set in an account, and how the pieces that Terraform cannot drive
are handled without pretending they are automated.

Two alternatives for the source were considered.

**Identity Center's own store.** Users and groups are created in the AWS console
or by `aws_identitystore_user` and `aws_identitystore_group`. Every membership
change is then an AWS change, made by whoever has Identity Center administration,
invisible to the directory's access reviews, and orphaned when the person leaves
the directory. Two instances mean two stores to keep in step with each other and
with Entra.

**Entra ID over SAML and SCIM.** Users sign in with their Entra credentials and
Conditional Access; SCIM copies the users and groups that are assigned to the
Entra gallery application into the identity store; the AWS side only ever grants
permission sets to groups it did not create. Membership stays where it is
governed. Two instances mean two gallery applications in one tenant, each fed by
the groups meant for its partition.

## Decision

**Entra ID is the identity source for every Identity Center instance.**
`stacks/entra-aws-federation` instantiates the gallery application once per
instance from a map, configures SAML, generates the signing certificate in
Entra, assigns the groups, and configures SCIM. `stacks/aws-identity-center`
manages permission sets and account assignments and resolves groups by display
name in the identity store. Neither stack creates a user or a group.

**Assignment is by group, and only by group.** `modules/aws/account-assignment`
fixes `principal_type` to `GROUP` and has no user input. A person-to-permission
edge belongs in the directory: that is where it is reviewed, where PIM for
groups makes it just in time, and where it disappears when the person leaves. A
user assignment in AWS would bypass all three and outlive them.

**The group name is the assignment.** Every AWS access group is named

```
AWS-<PARTITION>-<accountId>-<PermissionSetName>
```

with `PARTITION` in `COM` or `GOV`, a 12-digit account ID, and the name of a
permission set. The regex `^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$` is enforced by
validation on both sides. On the Entra side, `stacks/entra-aws-federation` takes
one list of groups and assigns each to the gallery application whose
`partition_token` matches the name, which is what provisions it into that
instance. On the AWS side, `modules/aws/account-assignment` parses the name and
creates exactly one assignment: that permission set, in that account, for that
group. It checks that the partition token matches the partition the provider is
actually talking to (from `data.aws_partition`) and that the permission set is
one the same cell defines, and fails the plan with the group name otherwise.

This works because the name is self-describing. An access reviewer who sees
`AWS-COM-111111111111-ReadOnly` in an Entra access review knows what membership
grants, in which account, without opening the AWS console or this repository.
Provisioning and assignment derive from one artifact, the group, so they cannot
disagree: a group that exists in the identity store has an assignment because
its name says so, and a group with an assignment exists because it is assigned
to the application. There is no second list of accounts and permission sets to
keep aligned with the first, and there is no ID in any cell except the account
ID the convention carries.

**Groups are assigned with the application's default app role.** The module
reads the roles the instantiated service principal publishes and uses the one
enabled user-assignable role named `User` (what gallery applications publish and
what the portal picks by default); if the application publishes no such role it
uses the well-known default role ID `00000000-0000-0000-0000-000000000000`,
which the azuread provider documents for that case; if it publishes several and
none matches, the plan fails listing them. No role GUID is copied into the
repository.

**The SCIM secret never lands in code.** The SCIM endpoint and bearer token are
issued by the AWS console, once. They reach Terraform as `TF_VAR_scim_credentials`,
a map keyed like the targets, declared `sensitive` in the stack and the module,
and set from a GitHub environment secret in CI or an exported variable locally.
No cell, module, generated file, or plan comment contains them. A target with
SCIM enabled and no credentials fails validation naming the target, so a
missing secret is a failed plan and never a destroyed provisioning job. What the
provider does with the values is stated plainly rather than hidden:
`azuread_synchronization_secret` stores them in state, and a saved plan file
carries them too. The state container is Entra-authenticated with no shared keys
(ADR 0004), plan artifacts expire, and the token is rotated from the AWS console
when either is a concern.

**Two steps stay manual, in a fixed order.** Identity Center exposes neither the
identity source switch nor the SCIM enablement through an API Terraform can
drive, and both are one-shot: the "Change identity source" wizard consumes the
IdP metadata and will not run again while an external provider is set, and the
SCIM token is displayed once. The order is: apply the Entra cell with SCIM off;
finish the AWS wizard with the federation metadata; enable automatic provisioning
and copy the endpoint and token; confirm the synchronization template ID against
`GET /servicePrincipals/{id}/synchronization/templates`; export the credentials
and apply again with SCIM on; wait for the first cycle; then plan the AWS cell,
whose group lookups fail until the groups exist. The module README carries the
steps. Pretending these were automated would mean a resource that creates
nothing and a README that lies.

## Consequences

- A group in the Entra cell's `aws_groups` and not in the matching AWS cell's
  `group_display_names`, or the reverse, is caught at plan time: missing on the
  Entra side, the AWS group lookup fails; missing on the AWS side, the group is
  provisioned but grants nothing and the reviewer sees an unreferenced group.
  The two lists are kept in step by review, not by a cross-cloud Terragrunt
  dependency, which is the coupling ADR 0004 declined.
- Renaming a group is a new group. The name is the Terraform key on the AWS
  side, so the plan shows a destroy and a create, and SCIM shows a new object.
  That is correct: a group whose name says something different grants something
  different.
- A permission set name must be letters and digits so it can be carried in a
  group name. The stack validates it.
- SCIM provisions direct members of assigned groups only; nested groups are not
  flattened. Convention-named groups therefore hold people, not other groups.
  Where just-in-time access is wanted, the group is PIM-managed and activation
  writes the membership SCIM then carries across within minutes.
- The Azure workflows do not yet map `SCIM_CREDENTIALS` into
  `TF_VAR_scim_credentials`, so the federation cell is planned and applied from a
  workstation until that wiring is added. It is a one-line change per job and is
  the next piece of pipeline work.
- `modules/aws/account-assignment` no longer needs AWS Organizations permissions,
  because the account ID comes from the group name. A mistyped account ID fails
  at apply, when Identity Center refuses to provision into an account outside the
  organization.
