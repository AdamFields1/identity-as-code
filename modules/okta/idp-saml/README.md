# modules/okta/idp-saml

Manages a map of upstream SAML 2.0 identity providers and their signing keys.
It is the trust half of the Okta federation stack: a cell says who the identity
provider is, where Okta sends the AuthnRequest, which certificates Okta trusts
for the identity provider's signature and which one is active, how the asserted
subject is matched to an Okta user, and what happens to users the identity
provider asserts but Okta does not know. The request signature, the minimum
response signature algorithm, and the ACS binding are fixed here and are not
inputs.

## Design notes

- **Identity providers are a map keyed by logical name.** Adding or removing a
  trust never re-addresses its neighbours. The visible name is `name`, which
  must be unique across the map because Okta shows it on the routing rules
  screen and in every system log event for the trust.
- **Signing is fixed, not chosen.** Okta signs every AuthnRequest
  (`request_signature_scope = "REQUEST"`) with `SHA-256` and requires at least
  `SHA-256` on the identity provider's signature. None of these has an input.
  The one signature setting a cell chooses is `response_signature_scope`, which
  element must carry the identity provider's signature (`RESPONSE`,
  `ASSERTION`, or `ANY`), because that is the identity provider's behaviour, not
  Okta's: Entra signs the assertion by default, so a cell federating to Entra
  sets `ASSERTION`. It is required, with no default, for the same reason the
  algorithms are not a choice at all: `ANY` is the loosest of the three, it
  accepts a signature on either element, and it is what an omitted attribute
  would inherit with nothing in the plan or the diff to say so.
- **The AuthnRequest asks for the format the trust accepts.** `name_format`,
  the `Format` of the `NameIDPolicy` Okta sends, is fixed too, but derived
  rather than chosen: it is the first entry of `subject.format`. The provider
  would otherwise default it to
  `urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified`, so Okta would ask
  for an unspecified NameID while refusing anything but `subject.format` in
  the response. Entra ignores the `NameIDPolicy` and sends what its
  application is configured for, but an identity provider that honors it
  strictly would answer with an unspecified NameID and Okta would reject the
  assertion.
- **Certificates are PEM text, keys are Okta's.** A cell passes the identity
  provider's signing certificate as the PEM text a portal download or a
  certificate output hands over, typically `file()` of a `.cer` beside the
  cell. The module strips the `BEGIN CERTIFICATE` and `END CERTIFICATE` lines
  and every whitespace character to the base64 body Okta's `x5c` set expects
  and creates one `okta_idp_saml_key` per entry, addressed by the certificate
  it carries (`"<identity provider>/<entry>/<first twelve hex digits of the
  body's SHA-256>"`). The body is in the address on purpose: see the next
  note. Text outside the armor, such
  as a comment saying where the file came from, is ignored. An entry that is
  not exactly one certificate, whose body is not base64, or that carries a
  private key is refused. The base64 check is structural (alphabet, padding,
  length, and the `MII` prefix every DER certificate encodes to) because
  Terraform's `base64decode` insists on UTF-8 output, which DER never is.
- **Okta trusts exactly one kid per identity provider.** `active_certificate`
  names the entry whose key is the trust's `kid`. Rotation is: add the new
  file and entry, flip `active_certificate`, apply, and remove the old entry on
  a later apply once the identity provider has activated its new certificate.
  A key an identity provider still references cannot be deleted, which is why
  the flip comes first. The flip is coordinated with the other side's
  "make certificate active" step and is not zero-downtime by itself: between
  the two activations, one side signs with a certificate the other does not
  trust yet.
- **A changed certificate is a new key, never an updated one.** `x5c` is not
  `ForceNew` in the pinned provider, and `okta_idp_saml_key`'s `Update` is not
  a narrow one: it creates the new key, lists **every** SAML2 identity
  provider in the org, rewrites the `kid` of each one that still pointed at
  the old key, and deletes the old key. That reaches trusts this module does
  not manage and whose ids are nowhere in its state, and the plan for it shows
  nothing but `~ x5c` on one resource. Putting the certificate body in the
  resource address is what prevents it: editing a `.cer` in place is a create
  and a destroy rather than an update, so that code path never runs, and
  `create_before_destroy` gives the order Okta requires, the new key first,
  then the trust's `kid`, then the old key's deletion. Rotate by adding a file
  and an entry, as above, rather than by editing a file.
- **The issuer is the other side's identifier.** `issuer` is the string the
  identity provider puts in `<Issuer>`, checked as an https URL with a host and
  no wildcard. Entra publishes `https://sts.windows.net/<tenant id>/`, which
  has no name form, so a cell federating to Entra carries a tenant id there. It
  is not an Okta object id, which the cell rules forbid; it is a URL the other
  side publishes, like `sso_url`.
- **`sso_destination` defaults to `null`.** The provider treats that as the
  `sso_url`, which is what almost every identity provider expects; a cell sets
  it only when the identity provider documents a Destination that differs from
  its endpoint, and the override is in the diff.
- **The subject block is typed.** `match_attribute` belongs to
  `CUSTOM_ATTRIBUTE` and is refused elsewhere rather than dropped, so a mistake
  in the cell is visible instead of silent. `format` lists the NameID formats
  Okta accepts and defaults to the `emailAddress` URN; `username_template`
  defaults to `idpuser.subjectNameId`, the NameID as sent. `filter` is the
  regular expression an asserted username must match, and the Identity
  Providers API calls it a security best practice: with no filter, the
  identity provider may issue an assertion for any user of the org, partners
  and directory users included.
- **Provisioning defaults to `DISABLED`.** The directory of record provisions
  users, the same line `stacks/okta-config` draws; just-in-time creation is
  opt-in with `provisioning.action = "AUTO"`. The group fields belong to a
  `groups_action` each: `groups_attribute` and `groups_filter` to `SYNC` and
  `APPEND`, `groups_assignment` to `ASSIGN`. The fields that do not belong to
  the chosen action are refused rather than dropped.
- **Account linking defaults to `AUTO`, and `AUTO` has to be fenced.** An
  asserted user is joined to the existing Okta user the subject match finds.
  `AUTO` with neither `subject.filter` nor `account_link.group_include` is
  refused, because it is an automatic link from any subject the identity
  provider cares to assert to whichever Okta account the match type finds,
  Okta super administrators included; the error message says so. Those two are
  the only account-link guards `okta_idp_saml` exposes, since the API's
  account-link filter (exclude named users, exclude administrators) is not an
  attribute of the resource. Provisioning and account linking cannot both be
  `DISABLED` either: Okta would neither create nor link the asserted user, so
  nobody could sign in through the trust.
- **Groups are ids the stack passes.** `groups_filter`, `groups_assignment`,
  and `group_include` take Okta group ids. The calling stack resolves names
  with `data.okta_group`, the way `okta-config` resolves `groups_included`, so
  the lookup happens once per stack and a name that does not exist fails the
  plan with the name in the error.
- **`max_clock_skew` is milliseconds.** The Identity Providers API takes an
  integer whose documented example is 120000, the two minutes the admin console
  offers by default, and the provider passes it through unchanged. The module
  default is 120000.
- **Nothing secret is created or stored.** A signing certificate is public key
  material; the private half stays with the identity provider and is never
  written here. The module outputs only ids, kids, and thumbprints.

## Usage

```hcl
module "identity_providers" {
  source = "../../modules/okta/idp-saml"

  identity_providers = {
    entra = {
      name    = "Entra ID (corp tenant)"
      issuer  = "https://sts.windows.net/11111111-1111-1111-1111-111111111111/"
      sso_url = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/saml2"

      signing_certificates = {
        "2026" = file("${path.module}/entra-signing-2026.cer")
      }
      active_certificate = "2026"

      response_signature_scope = "ASSERTION"

      subject = {
        match_type = "EMAIL"
        format     = ["urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"]
        filter     = "(\\S+@example\\.com)"
      }

      provisioning = {
        action = "DISABLED"
      }

      account_link = {
        action        = "AUTO"
        group_include = [data.okta_group.this["all-workforce"].id]
      }
    }
  }
}
```

Rotating the certificate is two entries and a flip:

```hcl
signing_certificates = {
  "2026" = file("${path.module}/entra-signing-2026.cer")
  "2027" = file("${path.module}/entra-signing-2027.cer")
}
active_certificate = "2027"
```

Apply that after the other side has activated its 2027 certificate, then remove
the `"2026"` entry in a later change.

## What this module refuses

- A `name` that is blank or longer than 100 characters, or two identity
  providers with one name.
- An `issuer`, `sso_url`, or `sso_destination` that is not https, has no host,
  or contains a wildcard.
- An empty `signing_certificates` map; an `active_certificate` that is not one
  of its keys.
- A `signing_certificates` entry that is not exactly one PEM certificate: no
  armor, two certificates, an `END` line before the `BEGIN` line, or anything
  that says `PRIVATE KEY`; a body that is not base64 (alphabet, padding, a
  length that is a multiple of four, the `MII` prefix).
- A `status`, `issuer_mode`, `sso_binding`, `acs_type`, or
  `response_signature_scope` outside its allowlist, or a
  `response_signature_scope` left out (it has no default); a `max_clock_skew`
  that is negative or not a whole number.
- A `subject.match_type` outside its allowlist; `CUSTOM_ATTRIBUTE` without
  `match_attribute` or `match_attribute` without `CUSTOM_ATTRIBUTE`; an empty,
  repeated, or malformed `subject.format` entry; a blank `username_template`;
  an empty `filter` (leave it null instead).
- A `provisioning.action`, `deprovisioned_action`, `suspended_action`, or
  `groups_action` outside its allowlist; `SYNC` or `APPEND` without
  `groups_attribute`, or `groups_attribute` with `NONE` or `ASSIGN`;
  `groups_filter` with `NONE` or `ASSIGN`; `ASSIGN` without
  `groups_assignment`, or `groups_assignment` with any other action.
- An `account_link.action` outside its allowlist; `group_include` with
  `DISABLED`; `AUTO` with neither `subject.filter` nor `group_include`, which
  would link any asserted subject to any matching Okta account; provisioning
  and account linking both `DISABLED`.
- A blank or repeated id in any group list.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `identity_providers` | `map(object)` | n/a | SAML identity providers keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `identity_providers` | Map of key to `{ id, name, status, audience, acs_type, active_certificate, kid, keys }`, where `keys` maps every certificate name to `{ kid, x5t_s256, expires_at }`. |
| `identity_provider_ids_by_name` | Map of identity provider display name to identity provider ID. |

## Import

An identity provider imports by its ID and a key by its kid. The key address
is `<identity provider key>/<certificate name>/<first twelve hex digits of the
SHA-256 of the base64 body>`, so take it from the plan (or from
`sha256` of the armor-stripped, whitespace-stripped body) rather than typing
it:

```hcl
import {
  to = module.identity_providers.okta_idp_saml.this["entra"]
  id = "0oa0000000000000000"
}

import {
  to = module.identity_providers.okta_idp_saml_key.this["entra/2026/0123456789ab"]
  id = "your-key-id"
}
```
