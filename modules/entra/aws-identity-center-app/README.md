# modules/entra/aws-identity-center-app

Manages one AWS IAM Identity Center enterprise application in Entra ID: the gallery
application and its service principal, the SAML endpoints, a signing certificate,
the group assignments that put people in scope, and SCIM provisioning to the
Identity Center instance. One module instance per Identity Center instance; the
`entra-aws-federation` stack calls it once per target.
The general form of this pattern, a map of SAML service providers, gallery or
custom, with claims, groups, and optional provisioning, is
`modules/entra/saml-enterprise-app`; this module keeps only what Identity
Center adds to it, the group naming convention and the partition check.

## The naming convention

Every group assigned to the application is named

```
AWS-<PARTITION>-<accountId>-<PermissionSetName>

AWS-COM-111111111111-PlatformAdmin
AWS-GOV-333333333333-ReadOnly
```

`PARTITION` (`COM` or `GOV`) must equal the module's `partition_token`, which says
which Identity Center instance this application federates. A validation rejects
a group for the other partition, because a group provisioned into the wrong
instance can never be assigned there. The regex is
`^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$`, the same one
`modules/aws/account-assignment` enforces.

The name is the assignment. Being assigned here provisions the group into the
instance (SCIM, same display name); the AWS cell for that instance parses the
name and grants `PermissionSetName` in `accountId`. One artifact, both sides:
an access reviewer reading the group name in Entra knows what membership grants
without opening AWS, and provisioning and assignment cannot disagree because they
derive from the same string. See
[ADR 0008](../../../docs/adr/0008-entra-id-as-the-identity-source-for-aws.md).

## Design notes

- **Gallery template, not a custom SAML app.** The application is instantiated
  from the "AWS IAM Identity Center (successor to AWS Single Sign-On)" gallery entry
  because that is what carries the provisioning connector. A custom SAML application
  has no synchronization templates and SCIM could not be configured from code.
  `azuread_application` with `template_id` instantiates the template;
  `azuread_service_principal` with `use_existing = true` adopts the service
  principal the instantiation created.
- **Assignment is the scope.** `app_role_assignment_required` is forced on, and
  `assigned_groups` is the only way into the application. A group that is assigned
  is provisioned by SCIM and can sign in; a group that is not assigned does not
  exist on the AWS side. Users are never assigned directly (ADR 0008). SCIM
  provisions only direct members of an assigned group; nested groups are not
  flattened, so the convention-named groups hold people, not other groups.
- **The default app role is resolved, not typed.** `azuread_app_role_assignment`
  accepts the ID of a role the application publishes, or the well-known default
  role ID `00000000-0000-0000-0000-000000000000` for an application that publishes
  none. The module reads `app_roles` from the instantiated service principal and
  picks, in order: the one enabled user-assignable role named
  `app_role_display_name` (default `User`, the role gallery applications publish
  and the portal assigns by default); the well-known default ID if the application
  publishes no enabled user-assignable role at all; otherwise a plan failure that
  lists what is published. No role GUID is ever copied into the repository.
- **SAML endpoints are enforced; branding is not.** `identifier_uris` (the
  Identity Center issuer URL) and `reply_urls` (the ACS URL) are required and
  enforced on every apply. Owners, tags, claims, and branding are covered by
  `ignore_changes`, the same inventory-and-guardrail contract as
  `modules/entra/app-registration` (ADR 0006). Both URL sets are required because
  the provider treats an empty set as "remove", and the gallery template does not
  preset them for Identity Center.
- **The signing certificate is Entra's.** `azuread_service_principal_token_signing_certificate`
  makes Entra generate the key pair. The private key never leaves the tenant; the
  public certificate reaches AWS inside the federation metadata. Rotation is a new
  certificate here and a metadata re-upload in the AWS console.
- **SCIM credentials are variables marked sensitive.** `scim_base_address` and
  `scim_secret_token` are never literals. The stack takes them from
  `TF_VAR_scim_credentials`; the cell does not mention them. The provider stores
  both in state and in any saved plan, which is why the state container and plan
  artifacts are access controlled and why the token is rotated from the AWS console
  rather than treated as permanent (ADR 0008).

## What stays manual in the AWS console, and in what order

Identity Center exposes neither the identity source switch nor the SCIM enablement
through an API that Terraform can drive, and both are one-shot: the metadata upload
wizard refuses to run again while an external provider is configured, and the SCIM
token is shown once. The sequence is:

1. **Apply this module with `scim_enabled = false`.** That creates the application,
   the service principal, the certificate, and the group assignments. The identifier
   and reply URLs come from the AWS console's "Change identity source" wizard
   (service provider metadata, or the issuer and ACS URL patterns
   `https://<region>.signin.aws.amazon.com/platform/saml/<id>` and
   `.../platform/saml/acs/<id>` in commercial); the wizard can stay open while the
   apply runs.
2. **Download the federation metadata XML** from the enterprise application's
   single sign-on page (or from
   `https://login.microsoftonline.com/<tenant id>/federationmetadata/2007-06/federationmetadata.xml?appid=<client id>`),
   and finish the AWS wizard: External identity provider, upload the metadata, type
   ACCEPT. Compare the certificate thumbprint AWS shows against the module's
   `signing_certificate.thumbprint` output.
3. **Enable automatic provisioning** in the AWS console (Settings, Identity source,
   Automatic provisioning, Enable). Copy the SCIM endpoint and the access token
   before closing the dialog; there is no second look.
4. **Confirm the synchronization template ID.** With the application in place,
   `GET https://graph.microsoft.com/v1.0/servicePrincipals/<object id>/synchronization/templates`
   (Graph Explorer, `Synchronization.Read.All`) lists what the gallery application
   publishes. Microsoft's provisioning API walkthrough shows `aws` for the AWS
   connector and that is the module default; if the Identity Center entry in your
   tenant returns a different `id`, set `scim_template_id` to it.
5. **Export the credentials and re-apply with `scim_enabled = true`.** The secret
   is written, the job is created and enabled, and the first cycle runs within
   minutes; later cycles run about every 40 minutes. Provisioning logs are under the
   enterprise application.
6. **Only then plan the AWS cell.** `stacks/aws-identity-center` resolves groups by
   display name in the identity store; a group SCIM has not provisioned yet fails
   that plan with its name in the error, which is the intended order of operations.

Deprovisioning is the same in reverse: remove the group from `assigned_groups`,
SCIM removes it from the identity store on the next cycle, and the AWS cell's
assignment for that group then fails to resolve until it is removed too.

## Usage

```hcl
module "identity_center_commercial" {
  source = "../../modules/entra/aws-identity-center-app"

  display_name    = "AWS IAM Identity Center (commercial)"
  partition_token = "COM"
  identifier_uris = ["https://us-east-1.signin.aws.amazon.com/platform/saml/d-0000000000"]
  reply_urls      = ["https://us-east-1.signin.aws.amazon.com/platform/saml/acs/d-0000000000"]
  sign_on_url     = "https://d-0000000000.awsapps.com/start"

  notification_email_addresses = ["iam-alerts@corp.example.com"]

  assigned_groups = [
    "AWS-COM-111111111111-PlatformAdmin",
    "AWS-COM-111111111111-ReadOnly",
    "AWS-COM-222222222222-PowerUser",
  ]

  scim_enabled      = true
  scim_base_address = var.scim_credentials["commercial"].base_address
  scim_secret_token = var.scim_credentials["commercial"].secret_token
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `display_name` | `string` | n/a | Enterprise application display name. |
| `partition_token` | `string` | n/a | `COM` or `GOV`; every assigned group must carry it. |
| `gallery_template_display_name` | `string` | `"AWS IAM Identity Center (successor to AWS Single Sign-On)"` | Gallery entry to instantiate. |
| `identifier_uris` | `list(string)` | n/a | SAML audience: the Identity Center issuer URL. |
| `reply_urls` | `list(string)` | n/a | SAML ACS URL(s). |
| `sign_on_url` | `string` | `null` | AWS access portal URL for SP-initiated sign-in. |
| `relay_state` | `string` | `null` | RelayState for IdP-initiated sign-in. |
| `notification_email_addresses` | `list(string)` | `[]` | Certificate expiry notifications. |
| `assigned_groups` | `list(string)` | n/a | Convention-named Entra groups in scope. |
| `app_role_display_name` | `string` | `"User"` | Published default role to assign with. |
| `signing_certificate` | `object` | `{}` | `{ display_name, end_date }`. |
| `account_enabled` | `bool` | `true` | Sign-in switch. |
| `scim_enabled` | `bool` | `true` | Configure the synchronization secret and job. |
| `scim_template_id` | `string` | `"aws"` | Synchronization template published by the gallery app. |
| `scim_base_address` | `string`, sensitive | `""` | SCIM endpoint (Tenant URL). |
| `scim_secret_token` | `string`, sensitive | `""` | SCIM bearer token. |

## Outputs

| Name | Description |
|------|-------------|
| `application_object_id` | Application object ID. |
| `client_id` | Application (client) ID. |
| `service_principal_object_id` | Service principal object ID. |
| `signing_certificate` | `{ key_id, thumbprint, start_date, end_date }`. |
| `app_role_id` | The role ID the groups were assigned with. |
| `assigned_group_ids` | Group display name to object ID. |
| `app_role_assignment_ids` | Group display name to assignment ID. |
| `synchronization_job_id` | SCIM job ID, or null. |

## Import

```hcl
import {
  to = module.identity_center_commercial.azuread_application.this
  id = "/applications/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.identity_center_commercial.azuread_service_principal.this
  id = "/servicePrincipals/00000000-0000-0000-0000-000000000000"
}
```

The service principal is also adopted automatically by `use_existing`, so the
second block is only needed to adopt a hand-built application whose SAML settings
you intend to enforce from now on. The signing certificate, the synchronization
secret, and the job are recreated rather than imported; a re-created certificate is
a metadata re-upload in AWS.
