# stacks/okta-federation

The deployable unit that makes an upstream SAML 2.0 identity provider part of
an Okta org. It composes two modules into one plan and one state file:

1. `idp-saml` creates the identity providers and their signing keys from the
   certificates the other side publishes, with groups named rather than id'd.
2. `idp-routing-rules` creates the rules on the org's identity provider
   discovery policy that send matched sign-ins to those identity providers by
   key, with zones and applications named rather than id'd.

In this repository the identity provider is the corp Entra tenant: Entra
asserts, Okta is the service provider, and a routing rule sends workforce
sign-ins to it. Tenant cells under `tenants/okta/<env>/okta-federation/` point
at this stack and provide values only, one fragment file per map plus the
identity provider's signing certificate as a `.cer` file beside the cell.
Onboarding an identity provider is an entry in a fragment and a certificate
file: the stack owns the wiring and the modules own the guardrails, so a cell
reads like a menu and a reviewer reads a diff of values. Every value a cell
sets is a name, a URL the other side publishes, or a public certificate;
nothing is typed from a console screen twice. See
[ADR 0017](../../docs/adr/0017-three-kinds-of-stack.md) for the kind of stack
this is and
[ADR 0020](../../docs/adr/0020-applications-are-catalog-shapes-with-guardrails.md)
for the catalog shape it borrows, and
[ADR 0022](../../docs/adr/0022-upstream-identity-providers-are-values-and-public-keys.md)
for this stack's own decisions: what is fixed, why a certificate sits beside a
cell, and why the trust takes two applies to bootstrap.

## What this stack does not manage

OIDC upstream identity providers (`okta_idp_oidc`) and social identity
providers are different shapes and are not offered here. The inverse
direction, Okta as an upstream identity provider for Entra (what Entra calls
external identities or direct federation), is a different trust and is out of
scope. The Entra side of this trust is an enterprise application per Okta org
in the corp `entra-enterprise-apps` cell (`okta-workforce` for the prod org
and `okta-workforce-dev` for the dev org, in its `saml-apps.hcl`), managed
by `stacks/entra-enterprise-apps`, and those applications' OAuth-consented
provisioning connectors are not managed anywhere in this repository. The
`IDP_DISCOVERY` policy itself is created by Okta with the org and only looked
up here. The groups the cells name are created in Okta by the upstream
identity provider (the corp Entra tenant, as the repository README presents
it), the network zones a rule names are created by the org's `okta-config`
cell, and the Okta Admin Console a rule excludes is created by Okta; this
stack reads all three with data sources and never hardcodes an id. If a
group, zone, or application named in a cell does not exist, the plan fails
early with the name in the error rather than creating a trust nobody can use
or a rule that matches nothing.

## How identity providers, zones, groups, and applications are referenced

A routing rule names the identity providers it routes to by the logical keys
used in `identity_providers`, for example `idps = ["entra"]`. The stack
resolves each key against the identity provider module's output and passes
the ids to the routing module as `idp_ids`, which also gives Terraform the
dependency edge it needs to create identity providers before rules. A
validation block rejects a key that is not in the map before the plan reaches
the API.

Inside an identity provider, the three group lists
(`provisioning.groups_filter`, `provisioning.groups_assignment`,
`account_link.group_include`) are group names, looked up by the stack once per
distinct name with `data.okta_group`. Inside a routing rule, `zones_included`
and `zones_excluded` are zone names as the org's `okta-config` cell names them,
looked up once per distinct name with `data.okta_network_zone`, and an `APP`
entry in `app_include` or `app_exclude` carries the application's label,
looked up once per distinct label with `data.okta_app` (the data source needs
only the label). The `IDP_DISCOVERY` policy is looked up with `data.okta_policy`
by the name Okta gives the one every org has, "Idp Discovery Policy", which is
how the provider's own documentation for the rule resource finds it. Nothing in
a cell is an id, and the `okta-config` cell of the same org applies first
because the zones it creates are what the rules name (the cells declare that
dependency).

The one value in a cell that looks like an id is the identity provider's
`issuer`. Entra publishes `https://sts.windows.net/<tenant id>/` as the
`<Issuer>` of every response and there is no name form of it, so the cell
carries the tenant id inside that URL. It is the other side's identifier, a
URL the other side publishes, like `sso_url`; it is not an Okta object id.

## Onboarding an identity provider

The other side's federation metadata gives the three values the cell needs:
the issuer (`issuer`), the single sign-on endpoint (`sso_url`), and the
signing certificate, which the cell carries as a `.cer` file beside it and
reads with `file()`. The cell says those, how the asserted subject is matched
to an Okta user, whether Okta creates users the identity provider asserts
(the default is no: the directory of record provisions users, the line
`okta-config` draws), and which certificate entry is active:

```hcl
inputs = {
  identity_providers = {
    entra = {
      name    = "Entra ID (corp tenant)"
      issuer  = "https://sts.windows.net/11111111-1111-1111-1111-111111111111/"
      sso_url = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/saml2"

      signing_certificates = {
        "2026" = file("${get_terragrunt_dir()}/entra-signing-2026.cer")
      }
      active_certificate = "2026"

      response_signature_scope = "ASSERTION"

      subject = {
        match_type = "EMAIL"
        format     = ["urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"]
        filter     = "(\\S+@example\\.com)"
      }

      provisioning = { action = "DISABLED" }

      account_link = {
        action        = "AUTO"
        group_include = ["all-workforce"]
      }
    }
  }
}
```

Everything the other side would otherwise be asked to accept is fixed by the
module and not in the cell: Okta signs every AuthnRequest with SHA-256, the
identity provider's signature is verified with at least SHA-256, the
`NameIDPolicy` asks for the first `subject.format`, the ACS binding is
HTTP-POST, and the issuer and endpoints are https with no wildcard.
`response_signature_scope` is the one signature setting the cell chooses,
because it describes the identity provider's behaviour: Entra signs the
assertion by default, so the cells set `ASSERTION`. It is required rather
than defaulted, so no trust inherits `ANY`, the scope that accepts a
signature on either element.

The two account-link lines are not optional decoration. `account_link.action`
is `AUTO`, so an asserted user is joined to the Okta user the subject match
finds; `subject.filter` is the pattern an asserted username must match, and
`group_include` is the group whose existing members may be linked. With
neither of those, the trust would link any subject the upstream cares to
assert to whichever Okta account matched it, an Okta administrator included,
and the module refuses that combination rather than shipping it.

The routing rule says who is sent there. Workforce sign-ins are the usernames
that end in the corp domain; the rule routes them to the trust by key and, in
prod, excludes the Okta Admin Console:

```hcl
inputs = {
  routing_rules = {
    workforce-to-entra = {
      name     = "Workforce to Entra"
      priority = 1
      patterns = [{ match_type = "SUFFIX", value = "example.com" }]
      idps     = ["entra"]

      app_exclude = [{ type = "APP", label = "Okta Admin Console" }]
    }
  }
}
```

The admin console exclusion in prod is the break-glass line: Okta
administrators keep signing in to Okta directly with the phishing-resistant
factors `okta-config` enrolls, so an Entra outage does not lock the org's
administrators out. The dev cell carries the same rule without the exclusion,
so dev proves the whole path including the console before prod relies on it.
The policy's default rule, which routes to Okta itself, is immutable and always
last, so a sign-in no rule matches still reaches the Okta sign-in page.

After apply, the `identity_provider_onboarding` output holds the two values
the other side configures, labelled the way the application catalogs label
theirs: `audience` (the SP entity id Okta computed for the trust) and
`acs_url` (`https://<okta_org_name>.<okta_base_url>/sso/saml2/<identity
provider id>`, the trust-specific assertion consumer service URL Okta
documents for `acs_type = "INSTANCE"`). Neither is secret. On the Entra side
they are the enterprise application's identifier and reply URL.

## Bootstrapping the trust in two applies

The two sides each publish values the other needs, and neither exists first,
so the trust is built in two applies with one download between them. The
parity is fixed: each Okta org has its own application in the corp
`entra-enterprise-apps` cell, `okta-workforce` for the prod org and
`okta-workforce-dev` for the dev org, and the two sides exchange three
values, issuer and certificate one way, audience and ACS URL the other.

One Entra application serves exactly one Okta org. An application carries one
identifier URI and one reply URL, and with `acs_type = "INSTANCE"` (the
default) Okta mints a distinct audience and a distinct
`/sso/saml2/<identity provider id>` ACS URL per trust, on that org's own
host. Adding a second org's reply URL to one application would mean one
assertion, issued for one audience, postable to either org's endpoint, so a
new org is a new entry in `saml-apps.hcl` rather than a second value on an
existing one.

1. **The Entra cell applies first, with provisional values.** The corp
   `entra-enterprise-apps` cell holds that org's entry with a provisional
   identifier and reply URL, because the Okta side's values do not exist yet.
   Entra mints the application's SAML signing certificate on that apply; the
   cell's `signing_certificates` output carries its thumbprint.
2. **The certificate crosses, and the Okta cell applies.** The certificate is
   downloaded in Base64 form from the Entra portal (the enterprise
   application's SAML signing certificate) and saved as
   `<cell>/entra-signing-<year>.cer`. The same bytes are in the
   `azuread_service_principal_token_signing_certificate` resource's `value`
   attribute, but no output of this repository exposes it, and the provider
   documents it as PEM without the `BEGIN CERTIFICATE` and `END CERTIFICATE`
   lines, which the module requires, so the portal download is the path. The
   Okta cell applies; the identity provider is created with that certificate
   as its key, the routing rule is created after it, and the
   `identity_provider_onboarding` output hands back the `audience` and
   `acs_url`.

   Check that the right file crossed before going on. The two sides print
   different hashes, so compare like with like: the Entra cell's
   `signing_certificates` thumbprint is a hex SHA-1 fingerprint, and the
   `thumbprint` in the `identity_providers` output is Okta's `x5t_s256`, the
   base64url SHA-256 of the DER. Either check settles it, from the file
   itself:

   ```sh
   # matches the Entra cell's signing_certificates thumbprint
   openssl x509 -in <cell>/entra-signing-<year>.cer -noout -fingerprint -sha1

   # matches the thumbprint in the identity_providers output
   openssl x509 -in <cell>/entra-signing-<year>.cer -outform DER \
     | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '='
   ```
3. **The Entra cell sets them and applies again.** On that org's entry,
   `identifier_uris` becomes its audience and `reply_urls` becomes its ACS
   URL; the apply updates the application in place. Each entry carries the one
   org's pair, so bootstrapping the second org adds an entry and never
   overwrites the first one's values. A test sign-in from a workforce account
   is the acceptance, and an administrator's direct sign-in to the admin
   console is the second one.

The issuer and the sign-on URL cross in step 2 as well, but they are the
tenant's and not the application's, so they are known before step 1 and the
Okta cell carries them from the start.

## Rotating the signing certificate

Okta trusts exactly one key per identity provider, the one `active_certificate`
names, so a rotation is two entries and a flip, coordinated with the Entra
side's "make certificate active" step:

1. Entra mints the new certificate (a new `signing_certificate` on that
   org's entry of the Entra cell, or a certificate added in the portal and
   left inactive). Download it in Base64 form as
   `<cell>/entra-signing-<year>.cer` beside the old one.
2. Add the entry and flip the active one; the old entry stays:

   ```hcl
   signing_certificates = {
     "2026" = file("${get_terragrunt_dir()}/entra-signing-2026.cer")
     "2027" = file("${get_terragrunt_dir()}/entra-signing-2027.cer")
   }
   active_certificate = "2027"
   ```

   Apply this at the same time Entra activates its new certificate. Between
   the two activations one side signs with a certificate the other does not
   trust yet, so the flip is a coordinated change with a short window, not a
   zero-downtime one by itself.
3. Once Entra has activated its new certificate and a sign-in has been seen
   through it, remove the `"2026"` entry and its file in a later change. A key
   an identity provider still references cannot be deleted, which is why the
   flip comes before the removal.

Add a file; do not edit one. `okta_idp_saml_key` does have an update in the
pinned provider, and it creates a new key, rewrites the `kid` of every SAML2
identity provider in the org that still pointed at the old one, trusts this
stack does not manage included, and then deletes the old key, all behind a
plan that shows only `~ x5c`. The module keeps that path unreachable by
putting the certificate body in the key's resource address, so replacing a
`.cer` in place is a create and a destroy rather than an update; rotating by
adding a file and flipping `active_certificate` is the shape the module and
the `.cer` headers both describe.

The `identity_providers` output shows both keys under `keys` while a rotation
is in progress, with each one's `expires_at`, so the reviewer can see which is
active and when the old one would have lapsed.

## What this stack refuses

The modules refuse everything about a single entry (see each module's README:
the URL rules, the allowlists, one certificate per entry and a base64 body,
`CUSTOM_ATTRIBUTE` without an attribute, group fields that do not belong to
the chosen action, `EXPRESSION` beside another pattern, zone lists with a
non-`ZONE` connection, more than ten identity providers on a rule). This stack
refuses what only the whole cell can show:

- A routing rule's `idps` entry that is not a key of `identity_providers`, or
  a rule with no `idps`, a blank one, or one twice.
- Two routing rules with one `priority`. A map has no order, so the priority
  is the order.
- Two identity providers with one display name. Okta allows it; the person
  choosing a trust on the routing rules screen cannot tell them apart.
- A blank or repeated group name in an identity provider's group lists, or a
  blank zone name in a rule's zone lists, because the stack looks each name up
  and a blank name is a lookup that can only fail.
- Zone names on a rule whose `network_connection` is not `ZONE`. The module
  would refuse the ids, but the stack would look the names up first, so the
  refusal is here, on the line the cell wrote.
- An `APP` entry without a label or with a name, or an `APP_TYPE` entry
  without a name or with a label. The label is what the stack resolves.
- At plan time, from the lookups: a group, zone, or application name that does
  not exist in the org, and an org whose identity provider discovery policy
  cannot be read.
- At plan time, from a postcondition: an application whose label is not the
  label the cell asked for. `data.okta_app` queries Okta with a starts-with
  match and keeps the first result when no exact label is found, so without
  the postcondition a mistyped or renamed label would bind a rule's include or
  exclude to some other application and still plan green.

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "okta"` block is
generated by Terragrunt from tenant inputs (`okta_org_name`, `okta_base_url`) and the
API token is read by the provider from the `OKTA_API_TOKEN` environment variable. The
stack can therefore be planned against any tenant with no code changes. The two
variables are declared exactly as `stacks/okta-config` declares them, because
the same generated provider block reads both stacks, and this stack also reads
them to build the ACS URL it outputs.

## Standalone use without Terragrunt

```hcl
provider "okta" {
  org_name = "example-org"
  base_url = "oktapreview.com"
  # api_token read from OKTA_API_TOKEN
}

module "okta_federation" {
  source = "./stacks/okta-federation"

  okta_org_name = "example-org"
  okta_base_url = "oktapreview.com"

  identity_providers = {
    entra = {
      name    = "Entra ID (corp tenant)"
      issuer  = "https://sts.windows.net/11111111-1111-1111-1111-111111111111/"
      sso_url = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/saml2"

      signing_certificates = {
        "2026" = file("${path.root}/entra-signing-2026.cer")
      }
      active_certificate = "2026"

      response_signature_scope = "ASSERTION"

      subject = {
        match_type = "EMAIL"
      }

      account_link = {
        action        = "AUTO"
        group_include = ["all-workforce"]
      }
    }
  }

  routing_rules = {
    workforce-to-entra = {
      name        = "Workforce to Entra"
      priority    = 1
      patterns    = [{ match_type = "SUFFIX", value = "example.com" }]
      idps        = ["entra"]
      app_exclude = [{ type = "APP", label = "Okta Admin Console" }]
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `okta_org_name` | `string` | Org subdomain. |
| `okta_base_url` | `string` | okta.com, oktapreview.com, okta-emea.com, okta.mil. |
| `identity_providers` | `map(object)` | Upstream SAML identity providers keyed by logical name, the `idp-saml` shape with group names in place of group ids. Default `{}`. |
| `routing_rules` | `map(object)` | Routing rules keyed by logical name, the `idp-routing-rules` shape with `idps` (keys of `identity_providers`) in place of identity provider ids, zone names in place of zone ids, and an application label on an `APP` entry in place of its id. Default `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `idp_discovery_policy_id` | The org's `IDP_DISCOVERY` policy ID, the first half of a rule's import address. |
| `identity_provider_onboarding` | Identity provider key to `{ audience, acs_url }`, what the other side configures (for Entra, the enterprise application's identifier and reply URL). |
| `identity_providers` | Identity provider key to `{ id, name, status, audience, acs_url, active_certificate, kid, thumbprint, keys }`. |
| `identity_provider_ids` | Identity provider key to identity provider ID. |
| `routing_rule_ids` | Routing rule key to rule ID. |
