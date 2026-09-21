# Upstream SAML 2.0 identity providers and their signing keys, keyed by the
# caller's logical name.
#
# The module is a catalog shape, not a pass-through. A cell says who the identity
# provider is (name, issuer), where Okta sends the AuthnRequest (sso_url and its
# binding), which certificates Okta trusts for the identity provider's signature
# and which of them is active now, how the asserted subject is matched to an
# Okta user, and what happens to users the identity provider asserts but Okta
# does not know. Everything a security reviewer would otherwise have to check
# on every trust is fixed here: Okta signs its AuthnRequests with SHA-256, the
# identity provider's signature is verified with at least SHA-256, and there is
# no input for turning either off.
#
# for_each is keyed by the caller's logical name rather than count, so adding or
# removing an identity provider in the middle of the map never re-addresses its
# neighbours.
#
# Certificates are PEM text as the other side publishes it. Okta's key resource
# takes the bare base64 body (the x5c form), so the module strips the BEGIN and
# END lines and every whitespace character and refuses anything that is not
# exactly one certificate. One okta_idp_saml_key is created per certificate
# entry, addressed by the body it carries, and the identity provider's kid is
# wired to the entry the cell names in active_certificate. Rotation is
# therefore: add the new entry, flip active_certificate, apply, and remove the
# old entry after the identity provider has activated its new certificate. Okta
# trusts exactly one kid per identity provider, so the flip is coordinated with
# the other side and is not zero-downtime by itself.
#
# Groups are ids here. The calling stack resolves names with the okta_group data
# source, the way okta-config resolves groups_included, so the lookup happens
# exactly once per stack and a missing group fails the plan with its name.

locals {
  # Every certificate of every identity provider, flattened to one key resource
  # each, keyed "<identity provider key>/<certificate name>".
  #
  # The value is the x5c body: the text between the BEGIN and END lines with
  # every whitespace character removed. Lines outside the armor (a comment that
  # says where the file came from) are ignored by construction. The variable
  # validation has already refused text that is not exactly one certificate, so
  # the regex has exactly one match.
  certificate_bodies = merge([
    for idp_key, idp in var.identity_providers : {
      for cert_name, pem in idp.signing_certificates :
      "${idp_key}/${cert_name}" => replace(regex("-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----", pem)[0], "/\\s+/", "")
    }
  ]...)

  # The resource address of each entry's key: the entry plus the first twelve
  # hex digits of its body's SHA-256. The certificate is part of the address on
  # purpose (see the resource below), so everything that references a key goes
  # through this map rather than building the address from names.
  certificate_keys = {
    for entry_key, x5c in local.certificate_bodies :
    entry_key => "${entry_key}/${substr(sha256(x5c), 0, 12)}"
  }

  certificates = {
    for entry_key, x5c in local.certificate_bodies :
    local.certificate_keys[entry_key] => x5c
  }
}

# One signing key per certificate entry, addressed by the certificate it
# carries.
#
# okta_idp_saml_key has an Update, and it is a dangerous one: the provider
# creates the new key, then lists EVERY SAML2 identity provider in the org and
# rewrites the kid of each one that still pointed at the old key, including
# trusts this module does not manage and whose ids are nowhere in its state,
# and the plan for it shows nothing but "~ x5c" on this resource. Editing a
# .cer in place would otherwise be exactly that update, because x5c is not
# ForceNew in the pinned provider.
#
# So the body is part of the resource address: a changed certificate is a
# different instance, which is a create and a destroy rather than an update,
# and the provider's Update never runs. create_before_destroy makes the order
# the one Okta requires: the new key is created, the identity provider's kid
# moves to it, and only then is the old key deleted, which Okta refuses while a
# trust still references it. Removing a certificate entry from the cell is
# still a plain delete.
resource "okta_idp_saml_key" "this" {
  for_each = local.certificates

  x5c = [each.value]

  lifecycle {
    create_before_destroy = true
  }
}

resource "okta_idp_saml" "this" {
  for_each = var.identity_providers

  name   = each.value.name
  status = each.value.status

  # The trust. issuer is the value the identity provider puts in <Issuer>; kid is
  # the Okta key that verifies its signature, wired to the active certificate
  # entry so a typo in active_certificate is a plan error, not a broken trust.
  issuer      = each.value.issuer
  issuer_mode = each.value.issuer_mode
  kid         = okta_idp_saml_key.this[local.certificate_keys["${each.key}/${each.value.active_certificate}"]].kid

  # Where Okta sends the AuthnRequest. sso_destination defaults to null, which
  # the provider treats as the sso_url; a cell sets it only when the identity
  # provider documents a Destination that differs from its endpoint.
  sso_url         = each.value.sso_url
  sso_binding     = each.value.sso_binding
  sso_destination = each.value.sso_destination

  # Where the identity provider posts the response. INSTANCE is the
  # trust-specific ACS URL, /sso/saml2/<identity provider id>; ORG is the one
  # shared by every identity provider in the org. The ACS binding is HTTP-POST
  # and is not an input of the provider.
  acs_type = each.value.acs_type

  # Fixed by the module. None of these has an input. Okta signs every
  # AuthnRequest with SHA-256 and requires at least SHA-256 on the identity
  # provider's signature. Which element must carry that signature (the
  # response, the assertion, or either) is the identity provider's choice and
  # is the one signature setting a cell sets.
  request_signature_algorithm  = "SHA-256"
  request_signature_scope      = "REQUEST"
  response_signature_algorithm = "SHA-256"
  response_signature_scope     = each.value.response_signature_scope

  # Also fixed, and derived rather than chosen: the Format of the NameIDPolicy
  # Okta puts in the AuthnRequest is the first entry of subject.format, the
  # formats this trust accepts back. The provider would otherwise default it to
  # urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified, so Okta would ask
  # for an unspecified NameID while refusing anything but subject.format in the
  # response. Entra ignores the NameIDPolicy and sends what its application is
  # configured for, but an identity provider that honors it strictly would
  # answer with an unspecified NameID and Okta would reject the assertion.
  name_format = each.value.subject.format[0]

  max_clock_skew           = each.value.max_clock_skew
  honor_persistent_name_id = each.value.honor_persistent_name_id

  # Subject: how the asserted NameID becomes an Okta username and which profile
  # attribute it is matched against. subject_match_attribute belongs to
  # CUSTOM_ATTRIBUTE only; the variable validation refuses it elsewhere, and it
  # is sent as null there to keep the API payload and the plan clean.
  subject_match_type      = each.value.subject.match_type
  subject_match_attribute = each.value.subject.match_type == "CUSTOM_ATTRIBUTE" ? each.value.subject.match_attribute : null
  subject_format          = each.value.subject.format
  subject_filter          = each.value.subject.filter
  username_template       = each.value.subject.username_template

  # Provisioning: what Okta does with a user the identity provider asserts. The
  # default is DISABLED, the same line okta-config draws: the directory of
  # record provisions users, and just-in-time creation is opt-in. The group
  # fields belong to a groups_action each; the validation refuses the others
  # and they are sent as null.
  provisioning_action  = each.value.provisioning.action
  deprovisioned_action = each.value.provisioning.deprovisioned_action
  suspended_action     = each.value.provisioning.suspended_action
  profile_master       = each.value.provisioning.profile_master
  groups_action        = each.value.provisioning.groups_action
  groups_attribute     = contains(["SYNC", "APPEND"], each.value.provisioning.groups_action) ? each.value.provisioning.groups_attribute : null
  groups_filter        = contains(["SYNC", "APPEND"], each.value.provisioning.groups_action) && length(each.value.provisioning.groups_filter) > 0 ? each.value.provisioning.groups_filter : null
  groups_assignment    = each.value.provisioning.groups_action == "ASSIGN" ? each.value.provisioning.groups_assignment : null

  # Account linking: whether an asserted user is joined to the existing Okta
  # user the subject match finds, optionally only when that user is in one of
  # the listed groups.
  account_link_action        = each.value.account_link.action
  account_link_group_include = each.value.account_link.action == "AUTO" && length(each.value.account_link.group_include) > 0 ? each.value.account_link.group_include : null
}
