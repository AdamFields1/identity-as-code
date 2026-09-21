# ADR 0022: Upstream identity providers are values and public keys

Status: accepted
Date: 2026-09-20

## Context

This estate has two identity providers. ADR 0020 gave the Okta tree an
application catalog and ADR 0021 gave the Entra tree the same, so a vendor
is onboarded into either provider from the same values. What neither
covered is the relationship between the providers themselves. The corp
Entra tenant is the directory of record: it holds the workforce accounts,
provisions the groups every Okta cell names, and enrolls the factors
Conditional Access evaluates. Okta is where the application catalog and the
sign-on policies live. For a workforce sign-in to reach an Okta application
with the factors Entra evaluated, Entra has to be an upstream SAML identity
provider for the Okta org: Entra asserts, Okta is the service provider, and
a rule on the org's identity provider discovery policy sends the usernames
under the corp domain to that trust. Until this change the repository had
no shape for that trust, and the two catalogs stood on either side of a gap
that a console session filled.

Hand-built federation fails in the same few ways, and each is a setting
nobody meant to choose. The identity provider's signing certificate is
pasted from a portal download into a ticket, from the ticket into a wiki,
and from the wiki into the Okta console, so its expiry is discovered by the
outage, its rotation is a support call, and nobody can say which copy is
the one Okta trusts. The AuthnRequest goes out unsigned, because signing
it is a checkbox the console leaves clear, and the identity provider's
signature is verified with whatever algorithm the default offered. The
routing rule matches every application, the Okta Admin Console included,
so an outage of the upstream identity provider, or a routing rule that is
wrong, locks the org's administrators out of the console they would fix it
from. Just-in-time provisioning is left on, because the console offers it
as the friendly default, so the identity provider creates Okta users the
directory of record never issued, with whatever profile the assertion
carried. The issuer, the sign-on URL, the audience, and the ACS URL are
typed from one console screen into the other, twice, and a transposed
character is a trust that fails on the first sign-in with a message about
the other side. None of these is a design decision; each is a default that
survived because nothing refused it.

## Decision

`stacks/okta-federation` is a platform stack (one cell in every Okta org,
`tenants/okta/<org>/okta-federation/`, the twelfth, counted by ADR 0017 as
amended) written as a fragment cell in the shape of the catalogs
(`identity-providers.hcl`, `routing-rules.hcl`), with two modules under
`modules/okta/` whose shapes carry the guardrails: `idp-saml` for the
identity providers and their signing keys, and `idp-routing-rules` for the
rules on the org's `IDP_DISCOVERY` policy. The Entra side of the trust is
entries of the catalog that already exists: `okta-workforce` and
`okta-workforce-dev` in
`tenants/azure/corp/entra-enterprise-apps/saml-apps.hcl`, custom SAML
applications whose identifier and reply URL are the Okta side's audience and
ACS URL (ADR 0021). One application per Okta org, because an application
carries one identifier URI and one reply URL while `acs_type = "INSTANCE"`
gives every trust its own audience and its own
`/sso/saml2/<identity provider id>` on that org's host; two orgs sharing one
application would mean one assertion, issued for one audience, postable to
either org's endpoint. No new Entra shape was built, because a service
provider is what that catalog onboards, and an Okta org is one.

**The shape.** Per identity provider, a cell says its display name; the
issuer and the single sign-on endpoint the other side publishes; the
signing certificates as a map of name to PEM text and which entry is
active; which element the identity provider signs (`response_signature_scope`,
because that is the identity provider's behaviour and not Okta's: Entra
signs the assertion by default, so the cells set `ASSERTION`; required with
no default, because `ANY` accepts a signature on either element and is what
an omitted attribute would inherit in silence); how the asserted subject is
matched to an Okta user (a match type from an allowlist, the NameID formats
accepted, the filter an asserted username must match, the username
template); whether Okta creates the users the identity provider asserts and
what happens to groups when it does; and whether an asserted user is
linked to an existing one. Per routing rule, a cell says its name and
priority; a pattern on the username or on one profile attribute; the
identity providers it routes to by the keys of the first map; a network
condition with zones by name only under `ZONE`; the applications it
includes or excludes by label or by type; and, optionally, the platforms.
Everything else is refused, not defaulted, so a mistake is visible in
review: a non-https or wildcard issuer or endpoint, an empty certificate
map or an active entry that is not in it, a field that belongs to another
match type or provisioning action, an unknown value on any allowlist, a
rule with no pattern or no identity provider, zone lists on a rule that is
not `ZONE`, an application entry whose field does not belong to its type,
two rules with one priority, two identity providers with one display name.

**What is fixed.** Okta signs every AuthnRequest
(`request_signature_scope = "REQUEST"`) with SHA-256, requires at least
SHA-256 on the identity provider's signature, and receives the response on
an HTTP-POST binding; none of these has an input. The `NameIDPolicy` format
of the AuthnRequest is fixed too, and derived rather than chosen: it is the
first entry of `subject.format`, so Okta asks for a format the trust
accepts back instead of the provider's `unspecified` default, which a strict
identity provider would answer with an unspecified NameID that Okta then
rejects. The routing target is
`SAML2`: every identity provider a rule names becomes a `SAML2` provider
block, and an OIDC or social identity provider is a different shape stated
as out of scope. The `IDP_DISCOVERY` policy is Okta's own, one per org, and
is looked up by the name Okta gives it and never created. The ACS URL is
the trust-specific one (`acs_type = "INSTANCE"`, the default), so each
identity provider has its own endpoint and the audience Okta computes is
that trust's.

**The certificate sits beside the cell as a file, and it is the one file()
a cell carries.** The identity provider's signing certificate is public key
material: the private half was generated by Entra, is held by Entra, and
never leaves it, so the certificate is a value the other side publishes, in
the same class as its sign-on URL. A cell carries it as
`entra-signing-<year>.cer` beside `terragrunt.hcl`, downloaded in Base64
form from the Entra portal, and the fragment passes it with
`file("${get_terragrunt_dir()}/entra-signing-<year>.cer")`, so the text is
read from beside the cell rather than pasted into it. The portal download is
the path: the same bytes are in the
`azuread_service_principal_token_signing_certificate` resource's `value`
attribute, but no output of this repository exposes it, and the provider
documents it as PEM without the `BEGIN CERTIFICATE` and `END CERTIFICATE`
lines, which are exactly what the module requires. ADR 0017 is amended
for the file: a `.cer` beside a cell, referenced by `file()` with
`get_terragrunt_dir()`, is the only non-`.hcl` file a cell directory holds
and the only function call an input may use to reach outside the cell's own
text. (An inline value builder such as `jsonencode`, which the AWS identity
center cell already carries, is a value and not an exception to anything.)
The module strips the
`BEGIN` and `END` lines and every whitespace character to the base64 body
Okta's `x5c` set expects, refuses an entry that is not exactly one PEM
certificate or whose body is not base64, refuses any text that says
`PRIVATE KEY`, and ignores the text above the armor, so the file says in
comment lines what it is and what replaces it. The two committed files are
self-signed placeholders generated with openssl whose private key was
written to the null device, so no key ever existed on disk: they are the
one non-secret this repository introduces on purpose that looks like one,
and the no-secrets lint has nothing to match in them.

**The issuer is a published value, not an Okta id.** Entra publishes
`https://sts.windows.net/<tenant id>/` as the `<Issuer>` of every response
and there is no name form of it, so a cell carries the tenant id inside
that URL, the placeholder `11111111-1111-1111-1111-111111111111` here. The
cell rule (ADR 0002) forbids Okta object ids because an id is a value only
one org can hold and nobody can review; the issuer is the other side's
identifier, the same in every org that trusts it, and a reviewer can check
it against the Entra tenant the way they check a URL. It is not an
exception to the rule; it is a URL.

**Names, never ids, resolved by the stack.** The three group lists of an
identity provider (`groups_filter`, `groups_assignment`, `group_include`),
the zones a `ZONE` rule names, and the application an `APP` entry excludes
are names and a label in the cell, looked up once per distinct value with
`data.okta_group`, `data.okta_network_zone`, and `data.okta_app`, the way
`okta-config` resolves `groups_included` and `zones_included`; the modules
take ids. A routing rule names its identity providers by the keys of the
`identity_providers` map, and the stack resolves each key against the
identity provider module's output, which is also the dependency edge that
creates identity providers before rules. Every cell carries
`dependencies = ["../okta-config"]` because the zones a rule may name are
created there, so `cells.py` places the federation cell beside the
applications cell in the wave after the config cell, and the release train
needed no job edit.

**The trust is bootstrapped in two applies.** Each side publishes values
the other needs and neither exists first. The Entra cell applies first with
a provisional identifier and reply URL, and Entra mints the signing
certificate; the certificate crosses as the `.cer` file and the Okta cell
applies, handing back the audience and the ACS URL in its
`identity_provider_onboarding` output, labelled the way the application
catalogs label their vendor onboarding values; the Entra cell sets them and
applies again, updating the application in place. The issuer and the
sign-on URL are the tenant's rather than the application's, so they are
known before the first apply and the Okta cell carries them from the start.
Three values cross in all, and none is typed from a console screen twice.

**The admin console is excluded in prod, and that is the break-glass line.**
The prod rule sends every username under the corp domain to Entra from
anywhere and excludes the Okta Admin Console by label, so Okta
administrators keep signing in to Okta directly with the phishing-resistant
factors `okta-config` enrolls, and an Entra outage, or a routing rule that
is wrong, does not lock the org's administrators out of the console they
would fix it from. This is the same principle as the Conditional Access
break-glass exclusion (ADR 0007) applied to the other direction: the path
that repairs the system must not depend on the system. The dev rule
carries no exclusion, so dev proves the whole path, console included,
before prod relies on it; that one line, and the Entra application each org
has of its own, are the only differences between the two cells. The
exclusion is looked up by label, and the stack asserts the label it got is
the label it asked for, because `data.okta_app` queries Okta with a
starts-with match and keeps the first result when no exact label exists: a
renamed or mistyped label would otherwise exclude some other application
and plan green, which is this break-glass line failing silently.

**Provisioning is opt-in.** `provisioning.action` defaults to `DISABLED`
and both cells leave it there: the directory of record provisions users,
the same line `okta-config` draws, and an identity provider that could
create Okta users from an assertion is a second writer to the directory
nobody declared. Account linking defaults to `AUTO`, so an asserted user is
joined to the Okta user the subject match finds; the module refuses both
`DISABLED` at once, because then nobody could sign in through the trust.
An org that wants just-in-time creation sets `AUTO` and the word is in the
diff, with the group fields that belong to the chosen `groups_action` and
no others.

**Account linking is fenced, and the module refuses it unfenced.** `AUTO`
on its own is a standing offer to link whatever subject the upstream cares
to assert to whichever existing Okta user the match type finds, Okta super
administrators included, which is why the Identity Providers API calls the
subject filter a security best practice. The module therefore refuses
`account_link.action = "AUTO"` unless the trust sets `subject.filter`, the
pattern an asserted username must match, or `account_link.group_include`,
the groups whose members may be linked. Both cells set both: the filter is
the corp domain and the group is the same `all-workforce` group the Entra
application assigns, so the set of people the trust can reach is stated
twice and narrowed on each side. Okta's account-link filter fields that
exclude named users or administrators outright are not attributes of
`okta_idp_saml`, so those two are the whole toolbox.

## Consequences

- **A missing zone, group, or application fails the plan.** A rule that
  names a zone the org's `okta-config` cell has not applied yet, an
  identity provider whose group lists name a group the directory has not
  provisioned, or an `APP` entry whose label is not in the org plans red
  with the name in the error. The `dependencies` block and the release
  train's wave order cover the zone case on a release; on a pull request
  that adds the zone and the rule together, say in the description which
  plan is expected to fail and why, as ADR 0020 says for the applications
  cell. An empty condition would be worse: a rule that matches nothing and
  looks applied.
- **Rotation is coordinated, not zero-downtime by itself.** Okta trusts
  exactly one kid per identity provider, the one `active_certificate`
  names. A rotation is a second `.cer` beside the cell, a second entry, and
  a flip of `active_certificate`, applied at the same time Entra activates
  its new certificate; between the two activations one side signs with a
  certificate the other does not trust yet, so the flip is a coordinated
  change with a short window. The old entry is removed on a later apply,
  because a key the identity provider still references cannot be deleted.
  The `identity_providers` output shows both keys with their expiry while a
  rotation is in progress.
- **A rotation adds a file; it never edits one.** `okta_idp_saml_key` does
  have an update in the pinned provider, and it is org-wide: it creates the
  new key, lists every SAML2 identity provider in the org, rewrites the
  `kid` of each one that still pointed at the old key, and deletes the old
  key, reaching trusts this stack does not manage and whose ids are nowhere
  in its state, behind a plan that shows only `~ x5c`. The module keeps that
  path unreachable by putting the certificate body in the key's resource
  address, so an edited `.cer` is a create and a destroy rather than an
  update, with `create_before_destroy` giving the order Okta requires. The
  `.cer` headers say to add a dated file rather than edit the one that is
  there.
- **The Entra side carries values Okta mints, one entry per Okta org.** An
  entry's `identifier_uris` and `reply_urls` are the audience suffix and
  the identity provider id Okta assigns on the first apply, so the corp
  cell holds provisional values until then and the real ones after; the
  comment on the entry says so. Each entry carries one org's pair, so
  bootstrapping the dev trust and then the prod trust adds a second entry
  rather than overwriting the first, and a third Okta org would be a third
  entry. That is the one place in the estate where
  a cell's value is an output of a cell in another family, and it is set
  by a person reading an output, not by a cross-family dependency, because
  the two trees release on separate trains against separate state.
- **The cell rule has one stated exception, and it is narrow.** A cell
  directory may hold a `.cer` and an input may call `file()` on it with
  `get_terragrunt_dir()`; nothing else changed. The lint did not need a
  new check for it, because a fragment is still one `inputs` attribute and
  the certificate is public, and `cells.py` found the new cells by their
  `terragrunt.hcl` with no change. A cell that needs any other file, or any
  other function that reaches outside its own text, has found a shape the
  catalog does not offer.
- **OIDC and social identity providers, the inverse direction, and the
  provisioning connector stay out of scope.** `okta_idp_oidc` and the
  social identity providers are different shapes with different guardrails
  and are stated rather than half-built; Okta as an upstream identity
  provider for Entra (external identities, direct federation) is a
  different trust in the other tree; and the OAuth-consented provisioning
  connector of either `okta-workforce` application is a person in a dialog,
  as ADR 0021 says of Google Workspace's.
- **What a first apply should confirm.** That the org has the
  `ADVANCED_SSO` feature, since the routing rule resource refuses an org
  without it; that the discovery policy is found under the name "Idp
  Discovery Policy" and the admin console under the label "Okta Admin
  Console", since both are looked up by the name Okta gives them; that the
  audience Okta computed and the ACS URL the stack built are what the
  Entra application accepts as its identifier and reply URL, and that the
  certificate in the `.cer` is the one Entra minted, checked against one of
  the two thumbprints with `openssl` as the stack README shows, since the
  two sides print different hashes (Okta's `x5t_s256` is the base64url
  SHA-256 of the DER; the Entra cell reports a hex SHA-1 fingerprint) and
  comparing them directly can only ever fail; that a workforce sign-in
  routes through Entra and
  lands on the linked Okta user without creating one, since provisioning
  is `DISABLED`; that an administrator's sign-in to the admin console in
  prod does not route upstream; that the second plan shows no diff on the
  signature settings, `max_clock_skew`, or the key set; and that the group
  and zone names the cells carry exist before the first plan, since the
  plan and not the apply is what fails otherwise.
