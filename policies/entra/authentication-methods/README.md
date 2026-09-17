# policies/entra/authentication-methods

The desired state of a tenant's Entra authentication methods policy, as the
JSON that Microsoft Graph accepts, with one difference: groups are named, not
numbered. `scripts/Set-AuthenticationMethods.ps1` reads this folder, resolves
every group display name to its object ID, compares the result with the live
policy, and reports or patches the difference. The runbook
`automation/runbooks/Invoke-AuthenticationMethodsDrift.ps1` reads the same
files from Automation variables that `stacks/azure-automation` publishes from
this folder. Neither the script nor the runbook has any other source of truth.
See [ADR 0012](../../../docs/adr/0012-authentication-methods-policy-as-desired-state.md)
for why this is a folder of JSON and not a Terraform resource.

```
policies/entra/authentication-methods/
  policy.json                    policy-level settings: registration campaign, report suspicious activity, system-preferred MFA
  methods/
    Fido2.json                   one file per authenticationMethodConfiguration, named by its Graph id
    MicrosoftAuthenticator.json
    TemporaryAccessPass.json
    Sms.json
    Voice.json
    Email.json
    SoftwareOath.json
    X509Certificate.json
```

## The file contract

**A method file is the PATCH body.** Each file under `methods/` is sent, after
name resolution, as the body of
`PATCH /policies/authenticationMethodsPolicy/authenticationMethodConfigurations/{id}`,
where `{id}` is the file name without `.json`. The file therefore carries
`@odata.type` (Graph requires it in the body), `state`, and whichever subtype
settings the tenant manages. It does not carry `id`; the file name is the id.

**Only what a file says is managed.** The comparison walks the desired file
and looks up each field in the live policy. A field that is absent from the
file is neither compared nor written, so `Sms.json` with only `state` manages
the switch and leaves the targets alone. Add a field to manage it; remove a
field to hand it back to the portal. The exception is a target list: when a
file lists `includeTargets` or `excludeTargets`, the whole list is managed,
and a live target that the file does not name is drift.

**Groups are display names.** In any `includeTargets`, `excludeTargets`,
`includeTarget`, or `excludeTarget` entry whose `targetType` is `group`, the
`id` field holds the group's display name. The script resolves it with
`GET /groups?$filter=displayName eq '<name>'` at run time and refuses to
continue if the name matches zero or more than one group, the same way the
Terraform stacks refuse an ambiguous `data "azuread_group"`. Two values are
passed through untouched: the literal `all_users`, which Graph defines as the
target meaning every user, and the all-zeros GUID
`00000000-0000-0000-0000-000000000000`, which Graph returns for an empty
feature `excludeTarget`. A `targetType` of `role` or `administrativeUnit`
(valid in a feature target) is passed through as given.

**Lists are sets.** Target lists are compared by `(targetType, id)` without
regard to order. Scalar lists such as `aaGuids` are compared as sorted sets.
`certificateUserBindings` entries are keyed by `priority` and
`authenticationModeConfiguration.rules` by `identifier`.

**Read-only fields are ignored.** `id`, `@odata.context`, `displayName`,
`description`, `lastModifiedDateTime`, and `policyVersion` on the policy and
on each configuration are never compared, so an exported file that still
carries them is harmless.

## policy.json

The policy-level object holds three settings, each patched through
`PATCH /policies/authenticationMethodsPolicy`:

| Key | What it is | API version |
|-----|------------|-------------|
| `registrationEnforcement.authenticationMethodsRegistrationCampaign` | the nudge that asks users to register Microsoft Authenticator or a passkey after an MFA sign-in: `state`, `snoozeDurationInDays` (0 to 14), `enforceRegistrationAfterAllowedSnoozes`, `includeTargets` with `targetedAuthenticationMethod` (`microsoftAuthenticator` or `Fido2`), `excludeTargets` | v1.0 (`enforceRegistrationAfterAllowedSnoozes` is beta) |
| `reportSuspiciousActivitySettings` | lets a user report an unexpected MFA prompt, which sets their user risk to high: `state`, one `includeTarget`, `voiceReportingCode` | beta only |
| `systemCredentialPreferences` | system-preferred MFA, which prompts with the strongest registered method: `state`, `includeTargets`, `excludeTargets` | beta only |

Because two of the three exist only on the beta endpoint, the script reads the
whole policy from `beta` (a superset of v1.0) and patches the policy object on
`beta` when the body carries a beta-only key. Method configurations are
patched on `v1.0`. The Graph property is named
`reportSuspiciousActivitySettings`; there is no `reportSuspiciousActivity`.

### policyMigrationState is deliberately not in the file

`policyMigrationState` moves a tenant from the legacy per-user MFA and SSPR
method settings to this policy. Its values are `preMigration` (this policy
governs authentication only; the legacy policies are still read),
`migrationInProgress` (this policy governs authentication and SSPR; the
legacy policies are still read), and `migrationComplete` (the legacy policies
are ignored). Setting `migrationComplete` switches off every method that
was enabled only in the legacy MFA or SSPR settings, tenant-wide, in one
write. That is a planned cutover with a checklist, not a value a drift job
should converge to, so the script never sends it unless it is both present in
`policy.json` and the run was started with `-AllowMigrationStateChange $true`.
Without the switch, a difference is reported and held. The shipped file omits
the key; a tenant that has finished its migration would add it like this,
and revert the switch afterwards:

```
{
  "registrationEnforcement": { ... },
  "policyMigrationState": "migrationComplete"
}
```

## What the sample standard says

| Method | Sample | Why |
|--------|--------|-----|
| Fido2 | enabled for `all_users`, self-service registration on, attestation enforced, key restrictions declared but not enforced | passkeys are the phishing-resistant default; `isAttestationEnforced` and `keyRestrictions` are marked deprecated in favour of `passkeyProfiles` (removal announced for October 2027) and still function today; a tenant that has migrated to passkey profiles adds `allowedPasskeyProfiles` to each target |
| MicrosoftAuthenticator | enabled for `all_users`, `authenticationMode` `any`, app and location context shown to everyone | the two feature settings that remain configurable. `numberMatchingRequiredState` is not in the file: number matching has been enforced for every push notification since May 2023 and the field is no longer on the v1.0 `microsoftAuthenticatorFeatureSettings` resource, so declaring it would be a diff against nothing |
| TemporaryAccessPass | enabled for the group `Onboarding TAP`, one-time use, 60-minute default, 10 to 480 minutes | TAP is an onboarding bootstrap, issued by the helpdesk to a scoped group, never a standing method for everyone |
| Sms | disabled | telephony is not phishing resistant; only `state` is managed so the targets stay as they were for a controlled re-enable |
| Voice | disabled, office phone not allowed | same reason |
| Email | disabled, external users may not use email OTP | email OTP is an SSPR fallback the tenant does not want, and `allowExternalIdToUseEmailOtp` is the separate switch for guests |
| SoftwareOath | enabled for `all_users` | third-party TOTP apps as the fallback for users without a phone that runs Authenticator |
| X509Certificate | enabled for `PIM Privileged Users`, `PrincipalName` bound to `userPrincipalName`, multi-factor by default, no issuer or policy OID rules | certificate-based authentication for the privileged population, so their MFA can be required to be phishing resistant by an authentication strength |

`SEC Break Glass Accounts` (excluded from the registration campaign),
`Onboarding TAP`, and `PIM Privileged Users` are placeholder names; the last
is created by `stacks/entra-pim-governance`, the other two with the tenant's
other groups.

## Adopting a tenant that already has a policy

```powershell
$token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
.\scripts\Set-AuthenticationMethods.ps1 -DesiredStatePath .\policies\entra\authentication-methods -Export $true -AccessToken $token
```

`-Export` writes the live policy into the folder layout with group IDs
replaced by display names, one file per known method, and logs (without
writing) the live `policyMigrationState`. Review the diff, trim each file to
the fields the tenant means to manage, and run again without `-Export`: the
report should show no drift. That is the zero-change gate of `tests/README.md`
applied to an object Terraform cannot import.

## Two rules the script enforces on its own

1. **It will not disable the last enabled method.** If the desired state,
   applied over the live state, would leave zero enabled method
   configurations, the run stops with an error before any write. A tenant with
   no enabled method cannot register MFA at all.
2. **It will not change `policyMigrationState` by accident.** See above.
