variable "identity_providers" {
  description = <<-EOT
    Upstream SAML 2.0 identity providers to manage, keyed by a stable logical
    name (for example "entra"). The key becomes part of the Terraform resource
    address, so renaming a key moves the resource in state. Change the visible
    name with "name".

    Allowed value sets below are the provider's, from
    https://registry.terraform.io/providers/okta/okta/latest/docs/resources/idp_saml,
    and the Identity Providers API's, from the Okta management OpenAPI
    specification (IdentityProviderPolicy, PolicySubject, Provisioning, and
    SamlAlgorithms schemas) published at
    https://developer.okta.com/docs/api/openapi/okta-management/management/tag/IdentityProvider/.

    name                     : display name in the admin console and in every
                               system log event for the trust. 1 to 100
                               characters. Unique across the map.
    status                   : ACTIVE (default) or INACTIVE.
    issuer                   : the value the identity provider puts in <Issuer>.
                               https only, a host, no wildcard. Entra publishes
                               https://sts.windows.net/<tenant id>/, which has
                               no name form, so a cell carries the tenant id
                               there; it is the other side's identifier, not an
                               Okta object id.
    issuer_mode              : which Okta domain appears as the SP entity id and
                               in the ACS URL: ORG_URL (default, the org's
                               okta.com domain), CUSTOM_URL (the custom domain),
                               or DYNAMIC (whichever the request arrived on).
                               The set is the API's IssuerMode enum.
    sso_url                  : the identity provider's single sign-on endpoint,
                               where Okta sends the AuthnRequest. https only.
    sso_binding              : HTTP-POST (default) or HTTP-REDIRECT.
    sso_destination          : the Destination attribute of the AuthnRequest.
                               Null (default) means the sso_url.
    acs_type                 : which assertion consumer service URL Okta
                               publishes for this trust: INSTANCE (default, the
                               trust-specific /sso/saml2/<id>) or ORG (the URL
                               shared by every identity provider in the org).
    signing_certificates     : map of certificate name (for example "2026") to
                               the identity provider's signing certificate as
                               PEM text, the form a portal download or a
                               certificate output hands over. Text outside the
                               BEGIN CERTIFICATE and END CERTIFICATE lines, such
                               as a comment saying where the file came from, is
                               ignored. Exactly one certificate per entry. At
                               least one entry.
    active_certificate       : the signing_certificates key Okta trusts now.
                               Every entry becomes an Okta key; only this one is
                               the identity provider's kid. Rotation flips it.
    response_signature_scope : which element must carry the identity provider's
                               signature: RESPONSE, ASSERTION, or ANY (either
                               satisfies Okta). Required, with no default, the
                               same way the algorithms are not a choice at all:
                               ANY is the loosest of the three and is what an
                               omitted attribute would inherit silently, so
                               every trust states which element it requires
                               signed. Entra signs the assertion by default, so
                               a cell federating to Entra sets ASSERTION.
    max_clock_skew           : milliseconds of clock difference Okta tolerates
                               when it checks the assertion's timestamps.
                               Default 120000, two minutes: the API's documented
                               example value and the admin console's default.
    honor_persistent_name_id : keep the account link when the assertion carries
                               a persistent NameID. Default true.

    subject                  : how the asserted NameID becomes an Okta user.
      match_type             : which Okta profile attribute the transformed
                               username is matched against: USERNAME (default),
                               EMAIL, USERNAME_OR_EMAIL, or CUSTOM_ATTRIBUTE.
      match_attribute        : the Okta profile attribute to match. Required
                               for CUSTOM_ATTRIBUTE, refused otherwise.
      format                 : NameID formats Okta accepts from the identity
                               provider, at least one. Default is the
                               emailAddress format,
                               urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress.
      filter                 : optional regular expression the asserted username
                               must match, for example "(\S+@example\.com)".
                               The API calls it a security best practice: with
                               no filter, the identity provider may issue an
                               assertion for any user of the org, including
                               partners, directory users, and administrators.
                               Required here whenever account_link.action is
                               AUTO and account_link.group_include is empty,
                               because those three together are an automatic
                               link from any asserted subject to any Okta
                               account the match type finds.
      username_template      : Okta expression that turns the asserted subject
                               into the Okta username. Default
                               idpuser.subjectNameId, the NameID as sent.

    provisioning             : what Okta does with a user the identity provider
                               asserts.
      action                 : AUTO (create the user just in time) or DISABLED
                               (default: reject a user Okta does not already
                               know, because the directory of record provisions
                               users, the line okta-config draws).
      deprovisioned_action   : NONE (default) or REACTIVATE, for a user Okta has
                               deprovisioned.
      suspended_action       : NONE (default) or UNSUSPEND, for a user Okta has
                               suspended.
      profile_master         : whether the identity provider is the source of
                               truth for the user's profile. Default false.
      groups_action          : NONE (default), SYNC, APPEND, or ASSIGN.
      groups_attribute       : the identity provider's user attribute that
                               carries group names. Required for SYNC and
                               APPEND, refused otherwise.
      groups_filter          : Okta group ids the SYNC or APPEND action may
                               touch. Optional for those two, refused otherwise.
      groups_assignment      : Okta group ids every asserted user is added to.
                               Required for ASSIGN, refused otherwise. Ids,
                               resolved from names by the calling stack.

    account_link             : whether an asserted user is joined to the
                               existing Okta user the subject match finds.
      action                 : AUTO (default) or DISABLED.
      group_include          : Okta group ids; when set, only existing users in
                               one of them may be linked. Ids, resolved from
                               names by the calling stack. Refused when action
                               is DISABLED. Required under AUTO when
                               subject.filter is null; either one narrows which
                               asserted subject may land on which Okta account.
                               Okta's account-link filters that exclude named
                               users or administrators outright are not
                               attributes of okta_idp_saml, so these two are
                               the only guards the resource offers.

    Fixed and not inputs: Okta signs every AuthnRequest (request_signature_scope
    REQUEST) with SHA-256, requires at least SHA-256 on the identity provider's
    signature, and the ACS binding is HTTP-POST. The NameIDPolicy format of the
    AuthnRequest (name_format) is fixed too, but derived rather than chosen: it
    is the first entry of subject.format, so Okta asks for a format it accepts
    back instead of the provider's unspecified default.
  EOT

  type = map(object({
    name                     = string
    status                   = optional(string, "ACTIVE")
    issuer                   = string
    issuer_mode              = optional(string, "ORG_URL")
    sso_url                  = string
    sso_binding              = optional(string, "HTTP-POST")
    sso_destination          = optional(string)
    acs_type                 = optional(string, "INSTANCE")
    signing_certificates     = map(string)
    active_certificate       = string
    response_signature_scope = string
    max_clock_skew           = optional(number, 120000)
    honor_persistent_name_id = optional(bool, true)

    subject = optional(object({
      match_type        = optional(string, "USERNAME")
      match_attribute   = optional(string)
      format            = optional(list(string), ["urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"])
      filter            = optional(string)
      username_template = optional(string, "idpuser.subjectNameId")
    }), {})

    provisioning = optional(object({
      action               = optional(string, "DISABLED")
      deprovisioned_action = optional(string, "NONE")
      suspended_action     = optional(string, "NONE")
      profile_master       = optional(bool, false)
      groups_action        = optional(string, "NONE")
      groups_attribute     = optional(string)
      groups_filter        = optional(list(string), [])
      groups_assignment    = optional(list(string), [])
    }), {})

    account_link = optional(object({
      action        = optional(string, "AUTO")
      group_include = optional(list(string), [])
    }), {})
  }))

  validation {
    condition     = alltrue([for p in var.identity_providers : length(trimspace(p.name)) >= 1 && length(p.name) <= 100])
    error_message = "name must be 1 to 100 characters and not blank. Okta shows it on the sign-in routing screen and in every system log event for the trust."
  }

  validation {
    condition     = length(distinct([for p in var.identity_providers : p.name])) == length(var.identity_providers)
    error_message = "name must be unique across identity_providers. Two trusts with one name are indistinguishable in the admin console, in the routing rules, and in the system log."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["ACTIVE", "INACTIVE"], p.status)])
    error_message = "status must be ACTIVE or INACTIVE."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.identity_providers : [
        for u in compact([p.issuer, p.sso_url, p.sso_destination]) :
        can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", u))
      ]
    ]))
    error_message = "issuer, sso_url, and sso_destination must be https URLs with a host and no wildcard, for example https://sts.windows.net/11111111-1111-1111-1111-111111111111/. http is refused because the AuthnRequest and the response would travel in clear; a wildcard is refused because the issuer is the string Okta compares against <Issuer> before it trusts a signature."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["ORG_URL", "CUSTOM_URL", "DYNAMIC"], p.issuer_mode)])
    error_message = "issuer_mode must be ORG_URL, CUSTOM_URL, or DYNAMIC, the API's IssuerMode enum."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["HTTP-POST", "HTTP-REDIRECT"], p.sso_binding)])
    error_message = "sso_binding must be HTTP-POST or HTTP-REDIRECT."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["INSTANCE", "ORG"], p.acs_type)])
    error_message = "acs_type must be INSTANCE (the trust-specific ACS URL) or ORG (the URL shared by every identity provider in the org)."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["RESPONSE", "ASSERTION", "ANY"], p.response_signature_scope)])
    error_message = "response_signature_scope must be RESPONSE, ASSERTION, or ANY, and it has no default: ANY accepts a signature on either element, which is the loosest of the three, and a trust should say which one it requires signed. The signing algorithm is fixed at SHA-256 and is not an input."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : p.max_clock_skew >= 0 && floor(p.max_clock_skew) == p.max_clock_skew])
    error_message = "max_clock_skew must be a whole number of milliseconds, zero or more."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : length(p.signing_certificates) > 0])
    error_message = "signing_certificates must hold at least one certificate. Okta verifies the identity provider's signature with one of these keys; a trust with none cannot accept any assertion."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(keys(p.signing_certificates), p.active_certificate)])
    error_message = "active_certificate must be a key of signing_certificates. It names the entry whose Okta key is the identity provider's kid; an entry that does not exist would be a trust with no key."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.identity_providers : [
        for pem in values(p.signing_certificates) :
        length(regexall("-----BEGIN CERTIFICATE-----", pem)) == 1
        && length(regexall("-----END CERTIFICATE-----", pem)) == 1
        && can(regex("-----BEGIN CERTIFICATE-----[\\s\\S]*-----END CERTIFICATE-----", pem))
        && !strcontains(pem, "PRIVATE KEY")
      ]
    ]))
    error_message = "Every signing_certificates entry must be exactly one PEM certificate: one BEGIN CERTIFICATE line, one END CERTIFICATE line after it, and nothing that says PRIVATE KEY. Text outside the armor is ignored, so a comment above the certificate is fine; a bundle, a bare base64 body, or a file that carries a private key is not."
  }

  validation {
    # The x5c body must be base64 that decodes to DER. Terraform's base64decode
    # insists the decoded bytes are UTF-8, which a DER certificate never is, so
    # the check is structural: the base64 alphabet, padding only at the end, a
    # length that is a multiple of four, and the "MII" prefix that every DER
    # certificate longer than 255 bytes (all of them) encodes to, because its
    # first two bytes are the SEQUENCE tag 0x30 and the long-form length 0x82.
    condition = alltrue(flatten([
      for p in var.identity_providers : [
        for pem in values(p.signing_certificates) :
        can(regex("^MII[A-Za-z0-9+/]+={0,2}$", replace(try(regex("-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----", pem)[0], ""), "/\\s+/", "")))
        && length(replace(try(regex("-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----", pem)[0], ""), "/\\s+/", "")) % 4 == 0
      ]
    ]))
    error_message = "The body of every signing_certificates entry must be the base64 of a DER certificate: base64 characters only, padding only at the end, a length that is a multiple of four, and the MII prefix every DER certificate starts with. A body that does not decode is a key Okta would reject at apply time; refusing it here puts the reason in the plan."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["USERNAME", "EMAIL", "USERNAME_OR_EMAIL", "CUSTOM_ATTRIBUTE"], p.subject.match_type)])
    error_message = "subject.match_type must be USERNAME, EMAIL, USERNAME_OR_EMAIL, or CUSTOM_ATTRIBUTE."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      (p.subject.match_type == "CUSTOM_ATTRIBUTE") == (p.subject.match_attribute != null && length(trimspace(coalesce(p.subject.match_attribute, ""))) > 0)
    ])
    error_message = "subject.match_attribute is required when subject.match_type is CUSTOM_ATTRIBUTE and refused otherwise. The API reads it only for CUSTOM_ATTRIBUTE; anywhere else it would be dropped silently, which hides a mistake in the cell."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      length(p.subject.format) > 0 && length(distinct(p.subject.format)) == length(p.subject.format) && alltrue([for f in p.subject.format : can(regex("^urn:oasis:names:tc:SAML:(1\\.1|2\\.0):nameid-format:[A-Za-z]+$", f))])
    ])
    error_message = "subject.format must list at least one NameID format URN, each once, of the form urn:oasis:names:tc:SAML:1.1:nameid-format:<name> or urn:oasis:names:tc:SAML:2.0:nameid-format:<name>, for example urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : length(trimspace(p.subject.username_template)) > 0])
    error_message = "subject.username_template must not be blank. The default, idpuser.subjectNameId, is the NameID as the identity provider sent it."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : p.subject.filter == null || length(trimspace(p.subject.filter)) > 0])
    error_message = "subject.filter, when set, must be a non-blank regular expression. Leave it null rather than empty."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["AUTO", "DISABLED"], p.provisioning.action)])
    error_message = "provisioning.action must be AUTO or DISABLED."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["NONE", "REACTIVATE"], p.provisioning.deprovisioned_action)])
    error_message = "provisioning.deprovisioned_action must be NONE or REACTIVATE."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["NONE", "UNSUSPEND"], p.provisioning.suspended_action)])
    error_message = "provisioning.suspended_action must be NONE or UNSUSPEND."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["NONE", "SYNC", "APPEND", "ASSIGN"], p.provisioning.groups_action)])
    error_message = "provisioning.groups_action must be NONE, SYNC, APPEND, or ASSIGN."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      contains(["SYNC", "APPEND"], p.provisioning.groups_action) == (p.provisioning.groups_attribute != null && length(trimspace(coalesce(p.provisioning.groups_attribute, ""))) > 0)
    ])
    error_message = "provisioning.groups_attribute is required when groups_action is SYNC or APPEND, the two actions that read group names from the assertion, and refused otherwise, where it would be dropped silently."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      contains(["SYNC", "APPEND"], p.provisioning.groups_action) || length(p.provisioning.groups_filter) == 0
    ])
    error_message = "provisioning.groups_filter is only read by SYNC and APPEND. With NONE or ASSIGN it would be dropped silently, which hides a mistake in the cell."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      (p.provisioning.groups_action == "ASSIGN") == (length(p.provisioning.groups_assignment) > 0)
    ])
    error_message = "provisioning.groups_assignment is required when groups_action is ASSIGN, the action that adds every asserted user to those groups, and refused otherwise, where it would be dropped silently."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.identity_providers : [
        for g in concat(p.provisioning.groups_filter, p.provisioning.groups_assignment, p.account_link.group_include) : length(trimspace(g)) > 0
      ]
    ]))
    error_message = "Group id lists (provisioning.groups_filter, provisioning.groups_assignment, account_link.group_include) must not hold a blank entry. The calling stack resolves names to ids; a blank means a lookup that produced nothing."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      length(distinct(p.provisioning.groups_filter)) == length(p.provisioning.groups_filter)
      && length(distinct(p.provisioning.groups_assignment)) == length(p.provisioning.groups_assignment)
      && length(distinct(p.account_link.group_include)) == length(p.account_link.group_include)
    ])
    error_message = "Group id lists must not repeat an id; Okta holds each as a set."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : contains(["AUTO", "DISABLED"], p.account_link.action)])
    error_message = "account_link.action must be AUTO or DISABLED."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : p.account_link.action == "AUTO" || length(p.account_link.group_include) == 0])
    error_message = "account_link.group_include restricts which existing users may be linked, so it is only read when account_link.action is AUTO. With DISABLED it would be dropped silently."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      p.account_link.action != "AUTO" || p.subject.filter != null || length(p.account_link.group_include) > 0
    ])
    error_message = "account_link.action AUTO with neither subject.filter nor account_link.group_include set would let this identity provider assert any subject at all and have Okta link it, automatically, to whichever existing user the match type finds anywhere in the org, Okta super administrators included. Set subject.filter to the pattern the trusted usernames match, for example \"(\\S+@example\\.com)\", or set account_link.group_include to the groups whose members may be linked, or both. These two are the only account-link guards okta_idp_saml exposes."
  }

  validation {
    condition     = alltrue([for p in var.identity_providers : p.provisioning.action == "AUTO" || p.account_link.action == "AUTO"])
    error_message = "provisioning.action and account_link.action cannot both be DISABLED. Okta would neither create the asserted user nor link it to an existing one, so nobody could sign in through the identity provider."
  }
}
