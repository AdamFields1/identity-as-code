# ADR 0012: The authentication methods policy is desired-state JSON, enforced by a script and watched by a runbook

Status: accepted
Date: 2026-09-16

## Context

The Entra authentication methods policy decides which second factors exist in
a tenant and for whom: whether passkeys are on, whether SMS is off, who may be
issued a Temporary Access Pass, whether Authenticator shows the app and the
location, whether users are nudged to register, whether they can report a
suspicious prompt. It sits underneath every Conditional Access policy in
`stacks/entra-conditional-access`: an authentication strength that requires a
phishing-resistant method is only as good as the policy that lets users
register one. It is the kind of thing this repository exists to put in code.

It cannot be a Terraform resource. The azuread provider (3.x) has no resource
for `authenticationMethodsPolicy` or any of its `authenticationMethodConfigurations`,
and the shape of the API is the reason: they are singletons that exist in every
tenant from day one, are read with one `GET`, and are changed only with
`PATCH`. Nothing is created, nothing is destroyed (a `DELETE` on a
configuration resets it to defaults rather than removing it), and there is
no ID to import because the ID is the type name. A resource whose whole
lifecycle is "patch the one that exists" fits the provider model badly, which
is why the provider has left it alone, and why the AzAPI provider's generic
resource would need `ignore_missing_property` and manual `import` blocks to
hold it at all.

The policy also references groups, and it references them by object ID.
Every other stack here takes a group by display name and resolves it at plan
time, so a reviewer can read a cell without opening the portal (ADR 0008
makes the same argument for AWS). The desired state for this policy needed
the same property.

Three further facts shaped the design. Two of the three policy-level settings
(`reportSuspiciousActivitySettings` and `systemCredentialPreferences`) exist
only on the beta endpoint. `policyMigrationState`, a property of the same
object, is the switch that retires the legacy per-user MFA and SSPR method
settings, and setting it to `migrationComplete` disables every method that
was enabled only in those legacy settings, tenant-wide, in one write. And a
policy that disables every method leaves a tenant unable to register MFA at
all.

## Decision

**The desired state is a folder of JSON, one file per configuration.**
`policies/entra/authentication-methods/methods/<Id>.json` is the PATCH body
for `authenticationMethodConfigurations/<Id>`, with `@odata.type`, `state`,
and the subtype settings the tenant manages; `policy.json` holds the three
policy-level objects. The file is the Graph shape, so the Graph documentation
is the schema and there is no translation layer to keep current when
Microsoft adds a field. One file per method keeps a review to the method that
changed and lets a tenant manage some methods and leave others to the portal:
only the fields a file names are compared or written.

**Groups are display names in the file and object IDs on the wire.** In every
target entry whose `targetType` is `group`, `id` carries the display name.
The script resolves it with a `displayName eq` filter at run time and refuses
zero or multiple matches, the same failure a `data "azuread_group"` gives a
stack. `all_users` and the all-zeros empty target pass through. `-Export`
reverses the mapping so an existing tenant can be adopted by writing its live
policy as files and trimming them until the comparison is clean, which is the
zero-change gate of `tests/README.md` applied to an object Terraform cannot
import.

**One script does the comparison and the patch; one runbook does the
watching; both run one library.** `scripts/Set-AuthenticationMethods.ps1`
reads the folder, reads the live policy from beta (a superset of v1.0),
computes a field-level drift list, prints it, and with `-DryRun:$false`
patches each drifted configuration on v1.0 and the policy object on beta
only when the body carries a beta-only property. `-FailOnDrift` turns it
into a pull request check. `automation/runbooks/Invoke-AuthenticationMethodsDrift.ps1`
runs the same comparison on a Sunday schedule from the same files, held as
Automation variables, and mails a digest when the tenant has moved. The diff,
plan, apply, and export functions live once, in
`automation/lib/AuthenticationMethods.Common.ps1`; the script dot-sources it
and the runbooks module inlines it into the runbook at deploy time, so the
pipeline and the runbook cannot disagree about what drift is.

**`policyMigrationState` is guarded, not converged.** The script never sends
it unless it is present in `policy.json` and the run was started with
`-AllowMigrationStateChange $true`. Without the switch, a difference is
reported and held. The shipped file omits the key. A migration is a planned
cutover with a checklist and a person watching; a drift job that reconverges
it on a schedule would turn a rollback into a re-outage.

**No plan may leave zero enabled methods.** The desired states are overlaid on
the live states, including live configurations the files do not mention, and
if no configuration would remain enabled the run stops with an error before
any write, dry or not.

**Terraform still owns delivery.** `stacks/azure-automation` publishes each
desired-state file as an Automation string variable (`desired_state_files`)
and publishes the runbook with the library inlined, so a change to the JSON
is a plan diff on a variable, a change to the library is a plan diff on the
runbook, and the runbook reads nothing that a portal edit could change under
it. The release train runs the script with `-DryRun:$false` after the corp
governance cell, because the policy names a group that cell creates, and the
subsidiary gate waits for it. The pull request workflow runs it read-only
with `-FailOnDrift` when the folder, the script, or the library changes, with
the reader identity.

## Consequences

- The repository now has a fourth kind of managed object: not a module, not a
  cell, not a runbook body, but a folder of desired-state JSON with its own
  README contract. `README.md` and `docs/architecture.md` show where it sits.
- The comparison is one-directional. Fields a file does not name are not
  managed, so adopting a tenant does not require describing every setting,
  and a portal change to an unmanaged field is invisible. Target lists are
  the exception: naming `includeTargets` manages the whole list.
- Two policy-level objects and one registration campaign field exist only on
  beta, so part of the enforcement is against an API version Microsoft calls
  unsupported for production. The method configurations, which carry the
  settings that matter most, are patched on v1.0. If the beta objects move to
  v1.0 the version rule in the library changes and nothing else does.
- `numberMatchingRequiredState` is not in the sample. Number matching has
  been enforced for every Authenticator push since May 2023 and the field is
  gone from the v1.0 feature settings; declaring it would be a diff against
  nothing. Fido2's `isAttestationEnforced` and `keyRestrictions` are still
  honoured but are marked deprecated in favour of `passkeyProfiles`, with
  removal announced for October 2027; the sample keeps them and the README
  says what to add when a tenant migrates.
- The runbook identity gains `Policy.ReadWrite.AuthenticationMethod`. A cell
  that runs the runbook dry only can narrow it to `Policy.Read.AuthenticationMethod`
  in `graph_app_roles`; the shipped corp cell keeps the write permission so
  that flipping `dry_run` is the same one-line change it is for the other
  runbooks.
- The runbooks module gained one optional input, `library_path`, and one
  rule: a runbook that uses it carries two marker lines exactly once. ADR
  0010's "runbooks are self-contained files" still holds for what is
  published; what changed is that one runbook's file is assembled at plan
  time rather than typed in full.
- The tests (`automation/tests/Set-AuthenticationMethods.Tests.ps1`) run the
  shipped files against a fixture of the beta `GET` response and assert zero
  drift, then flip one field at a time. That is the only check on the sample
  standard until a tenant is used; a first live run should be `-Export` into a
  scratch folder and a diff against the shipped files.
