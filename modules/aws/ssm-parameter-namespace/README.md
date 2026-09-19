# modules/aws/ssm-parameter-namespace

Reserves a map of SSM Parameter Store namespaces. Each entry is one
SecureString parameter, `<prefix>/placeholder`, encrypted with a named
customer managed key, whose value Terraform writes once as `placeholder` and
never manages again. It is the parameter namespace of
`stacks/apps/aws/payments-api`; the key it names comes from
`modules/aws/kms-key`, and the roles that may read under the prefix are
granted by the stack that composes the two.

## Design notes

- **The shape is the namespace, not the secrets.** The placeholder reserves
  the prefix so nothing else claims it, and proves the prefix, the key, and
  the grants written for it work end to end before a real secret exists. The
  application's real secrets are siblings under the same prefix, written by
  the secrets process; this module neither declares nor reads them, so no
  secret passes through a plan, a cell, or a commit.
- **The placeholder must never hold a real value.** The provider reads a
  parameter back decrypted on every refresh, so whatever the placeholder
  holds at refresh time lands in state and in the prior state of every plan
  file, where the read-only identity that plans pull requests can read it.
  `ignore_changes = [value]` exists so an accidental overwrite is not
  reverted by the next plan (which would put the overwritten value in front
  of every reviewer of that plan); it is not permission to write a value
  here. If a value is ever written into a placeholder by mistake, rotate it,
  then overwrite the placeholder with `placeholder` again.
- **Encryption is a customer managed key, and it is required.** `kms_key_id`
  is the key id or key ARN as the key module outputs it; SSM stores what it
  is given and reports it back, so an alias would plan a change on every run.
  Creating a Standard SecureString parameter encrypts the placeholder with
  the key, so the deploying identity needs `kms:Encrypt` on it, which the
  key's root statement lets its IAM policy grant.
- **Every placeholder is `prevent_destroy`.** It anchors a namespace an
  application reads at start-up, and a map edit must not be able to remove
  it. A prefix change is a replacement and is refused for the same reason.
- **Nothing is looked up.** The module reads no data source and costs
  nothing when another module depends on it.

## Usage

```hcl
module "parameters" {
  source = "../../modules/aws/ssm-parameter-namespace"

  namespaces = {
    app = {
      prefix     = "/payments-api/prod"
      kms_key_id = module.key.keys["app"].key_id
      tags       = { Application = "payments-api" }
    }
  }
}
```

## What this module refuses

- A `prefix` without a leading slash, with a trailing slash, with more than
  14 segments, with characters outside letters, digits, underscores,
  periods, and hyphens, or starting with `/aws` or `/ssm`.
- A prefix used twice.
- A KMS alias or alias ARN where a key id or key ARN is expected, and a
  namespace with no key at all.
- A destroy of a placeholder without lifting `prevent_destroy` in a dedicated
  change.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `namespaces` | `map(object)` | n/a | Namespaces keyed by logical name: `prefix`, `description`, `kms_key_id`, `tags`. See `variables.tf` for the validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `namespaces` | Map of key to `{ prefix, arn_prefix, placeholder_name, placeholder_arn, kms_key_id }`; `arn_prefix` is the namespace's own ARN, the string a policy grants with `/*` behind it. |
| `placeholder_arns_by_prefix` | Map of prefix to the placeholder parameter's ARN. |

## Import

A parameter imports by name.

```hcl
import {
  to = module.parameters.aws_ssm_parameter.placeholder["app"]
  id = "/payments-api/prod/placeholder"
}
```

An adopted placeholder keeps whatever value it has; `ignore_changes` means
the plan does not touch it. If that value is not `placeholder`, treat it as
the mistake above and rotate it.
