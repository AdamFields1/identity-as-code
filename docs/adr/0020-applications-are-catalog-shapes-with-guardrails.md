# ADR 0020: Applications are catalog shapes with guardrails

Status: accepted
Date: 2026-09-20

## Context

Until this change the README listed Okta applications, SAML and OIDC
integrations, and app sign-on policies as out of scope. The Okta tree held
the org's authentication baseline (zones, the session, MFA, and password
policies) and stopped at the door of every application. Onboarding an
application over SAML or OIDC is the everyday work of an identity engineer:
a vendor sends an onboarding guide with an ACS URL and an entity id, a
developer asks for a client id and a redirect URI, and someone with admin
rights clicks through the console until the test login works. It is the
most frequent change an identity team makes and the one this repository
had no shape for.

Hand-onboarded applications fail in the same few ways, and each one is a
setting nobody meant to choose. The implicit flow is left enabled because
the console offers it as a checkbox, so an access token travels in a URL
fragment. A wildcard redirect URI is accepted to make a staging host work,
and an attacker's host matches it. A client secret is read from the console
and pasted into a wiki, a ticket, or a Terraform variable, and from there
into state. SAML assertions go out unsigned, or signed with SHA-1, because
the default was never changed. A vendor's admin console, the application
where a compromised session does the most damage, sits behind the org's
default sign-on policy, which is password-only or whatever the first
engineer set. None of these is a design decision; each is a default that
survived because nothing refused it.

The catalog stacks of ADR 0017 already show the shape for this: a menu of
vetted shapes as values, guardrails in the modules, one state file per
cell, and no Terraform written per entry. The AWS catalog offers roles,
keys, and buckets that way; the Azure catalog offers identities, vaults,
and storage accounts. An Okta application is the same kind of thing, with
its own guardrails.

## Decision

`stacks/okta-applications` is a catalog in shape (ADR 0017's menu of
typed maps, guardrails in the modules, so its cell may be written as
fragments) and a platform stack in placement (one cell in every Okta org,
which is why `cells.py` classifies it platform and the README counts it
among the ten). It has one cell per org
(`tenants/okta/<org>/okta-applications/`) written as fragments
(`signon-policies.hcl`, `saml-apps.hcl`, `oauth-apps.hcl`), and three
modules under `modules/okta/` whose shapes carry the guardrails.

**Three shapes, each with what it fixes.**

- `app-signon-policy`: app sign-on policies (`okta_app_signon_policy`)
  with rules (`okta_app_signon_policy_rule`), keyed by logical name. A rule
  says access, factor mode, re-authentication frequency, possession and
  knowledge constraints (phishing resistant, hardware protected, device
  bound), a network condition by zone name, a managed or registered
  device, and groups by name. Fixed: every policy's catch-all rule is
  created with DENY, so every path to ALLOW is a named rule in the diff; a
  rule that allows single-factor access is refused unless the policy sets
  `allow_single_factor = true` with a reason string; the policy carries
  `prevent_destroy`, because destroying one reassigns every app on it to
  the org's permissive default. The module exposes a fact computed from the
  values, known at plan time: whether every ALLOW rule of a policy requires
  phishing-resistant possession.
- `app-saml`: custom SAML 2.0 apps (`okta_app_saml`) with group
  assignments by name. Fixed: response and assertion both signed, RSA-SHA256
  and a SHA256 digest, `honor_force_authn` true, no self-service
  assignment, https endpoints with a host and no wildcard, no inline hook,
  and a `GROUP` attribute statement must carry a filter so the assertion
  never lists every group a user is in.
- `app-oauth`: OIDC apps (`okta_app_oauth`) with group assignments by
  name. Fixed and derived from the type: `authorization_code` and
  `refresh_token` with the `code` response type only on web, browser, and
  native, so the implicit and hybrid flows cannot be requested;
  `client_credentials` on service, where the response type is `token`
  because the Okta app API requires it next to that grant and the provider
  appends it itself (the one exception to the rule that `response_types`
  never carries `token` or `id_token`, held by a precondition on the
  resource to grant types of exactly `client_credentials`, and not the
  implicit flow, which is a grant a service app cannot request and which
  has no redirect URI to land in); PKCE required on every redirect-based type, web included;
  `private_key_jwt` on web and service from a `jwks_uri` the cell
  supplies; refresh token rotation with a bounded leeway;
  `wildcard_redirect` disabled; automatic key rotation; no custom client
  id or client secret; `omit_secret` true.

**What a cell may say.** For a policy: its name, its rules, and the
single-factor flag with its reason. For a SAML app: label, ACS URL,
audience, an optional recipient and destination (default the ACS URL), the
NameID template and a format from an allowlist, attribute statements, an
optional single logout, hide flags, status, the groups, the tier, and the
policy key. For an OIDC app: label, type, redirect and post-logout URIs, a
JWKS URI, an optional groups claim as a filter (never an expression, which
would be a policy document by another name), consent method, login mode,
hide flags, status, the groups, the tier, the policy key, and two knobs
that put a word in the diff: `allow_client_secret` and
`allow_localhost_redirects`, the second for a dev org only. Everything
else is refused, not defaulted, so a mistake is visible in review.

**The stack checks across the maps at plan.** Every app's policy key is a
key of the policy map; an app whose tier is `admin` names a policy, and
that policy's every ALLOW rule requires phishing-resistant possession, read
from the policy module's computed fact as a precondition on the app id
outputs; no two apps share a label, within a map or across the two. A
service app names no policy, because client credentials has no user
sign-in for a policy to evaluate and the schema does not require one.

**Groups by name, from the upstream identity provider.** The groups a cell
names (`app-payroll-users`, `app-orders-admins`, `app-vendor-admins`) are
provisioned into Okta by the corp Entra tenant, which the README already
presents as the upstream identity provider, and are looked up with a data
source once per distinct name. Nothing in this repository creates them. A
name that does not exist fails the plan with the name in the error, which
is the honest failure: an empty assignment would look like a working app
that nobody can open.

**Sign-on policies are tiers a cell picks by key.** The worked cells carry
`standard-workforce` (two factors, re-authentication every twelve hours,
from a corporate zone or a managed device) and `admin-phishing-resistant`
(phishing-resistant and hardware-protected possession, re-authentication on
every sign-in). An app is standard tier unless its entry says `admin`, and
an admin app cannot be planned onto the standard policy or onto no policy.
Both policies are present in dev even though no dev app is admin tier, so
the admin shape applies in dev before prod carries an app on it.

**The vendor gets outputs, not a console session.** After apply,
`saml_vendor_onboarding` holds the four values a service provider asks for
(the entity id, the SSO URL, the metadata URL, and the signing certificate)
and `oauth_client_ids` holds each client id. None is secret; the
certificate is the public half of a key Okta generated.

**Secrets.** Web and service clients authenticate to the token endpoint
with `private_key_jwt` by default, so the cell supplies a JWKS URI and no
secret exists. When a client cannot hold a key pair, the cell sets
`allow_client_secret = true`, the token endpoint method becomes
`client_secret_basic`, and the word secret is in the diff. `omit_secret` is
fixed true either way, so the provider never reads the secret back: it is
not in state, not in a plan artifact, and not in an output. The app owner
reads it once from the admin console, after the apply that created the
app, and rotates it there. Public clients (browser and native) refuse the
knob, because a secret shipped in a bundle is not a secret.

## Consequences

- **A missing group fails the plan.** The cells name groups the upstream
  identity provider has to have provisioned first. A pull request that
  onboards an app for a group that does not exist yet plans red with the
  group's name; the practice is to provision the group first and open the
  pull request next, and where they must travel together, to say so in the
  description. The same is true of a zone name the org's `okta-config` cell
  has not applied yet, which is why each applications cell carries a
  `dependencies` block on its config cell and the release train applies the
  config cell first.
- **The org's default policy is still the permissive one.** The module
  creates each managed policy's catch-all with DENY, but the org's default
  app sign-on policy, which an app with no policy key stays on, is not
  managed here. A standard-tier app may name no policy; an admin-tier app
  may not. The provider applies `catch_all` at creation only, so a policy
  imported into the module keeps whatever its catch-all already said, and
  the module README says to check it once after an import.
- **Token lifetimes and authorization servers are a later catalog.**
  Scopes, claims, access and refresh token lifetimes, and the servers that
  issue them are their own shapes with their own guardrails, and are stated
  as out of scope rather than half-built. So are SWA, bookmark, and
  basic-auth apps, user profile mappings, and the apps' own provisioning of
  users and groups into the vendor.
- **The Okta trains moved to `cells.py` in the same change.**
  `okta-release` and `okta-pr-validation` took the AWS train's shape: the
  release train reads its cells and their waves from `cells.py --family
  okta` (dev's config cell, then dev's applications cell; prod's config
  cell planned at merge time and its saved plan approved at the gate; then
  prod's applications cell planned fresh after the gate and applied under
  `prod-apply` without a second approval, because the cell it depends on
  has just applied), and the pull request workflow plans only the cells a
  change selects. The environments, the `OKTA_API_TOKEN` handling, the S3
  state variables and their skip guard, and the plan artifact discipline are
  unchanged. A new Okta cell lands in its wave with no workflow edit.
- **A URN entity id is outside the shape today.** The SAML module holds
  `audience` to the same https-with-host rule as every other endpoint. A
  vendor whose entity id is a URN cannot be onboarded through this catalog
  until the shape grows a stated exception for it.
- **What a first apply should confirm.** That the system catch-all rule of
  each new policy reads DENY in the console, because the provider applies
  `catch_all` at creation and nothing checks it afterwards; that a policy
  whose constraints JSON omits the `OPTIONAL` flags shows no diff on the
  second plan; that a service app with no policy key is created on the org
  default without a diff on `authentication_policy` at the next plan; that
  the client secret of a client which opted into one is absent from state
  after the first apply; that the SAML signing certificate in
  `saml_vendor_onboarding` is the one the vendor's metadata import accepts;
  and that the group names in the cells have been provisioned by the
  upstream identity provider before the first plan, since the plan and not
  the apply is what fails otherwise.
