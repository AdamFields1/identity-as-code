variable "repositories" {
  description = <<-EOT
    ECR repositories to manage, keyed by a stable logical name (for example
    "app"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. The repository name is "name".

    name                 : the repository name, 2 to 256 characters of lowercase
                           letters, digits, hyphens, underscores, periods, and
                           slashes, for example orders-api/prod. Each slash-separated
                           segment starts and ends with a letter or digit and holds
                           no two separators in a row. Immutable (forces
                           replacement, which prevent_destroy refuses).
    kms_key_arn          : ARN of the customer managed KMS key the images are
                           encrypted with. Required. A key ARN, not an alias: ECR
                           stores and reports the ARN, and an alias would plan a
                           change on every run. ECR creates a grant on the key on
                           behalf of whoever creates the repository, so the deploying
                           identity needs kms:CreateGrant, kms:RetireGrant, and
                           kms:DescribeKey on it.
    keep_tagged_count    : how many of the newest images the lifecycle policy keeps,
                           1 to 1000. Default 30. The rule counts every image
                           whatever its tag, so a release tag does not exempt an
                           image from the count.
    untagged_expiry_days : days after push that an untagged image (a layer set a
                           later build superseded) expires, 1 to 365. Default 7.
    pull_role_names      : IAM role NAMES in this account that may pull from the
                           repository (BatchGetImage, GetDownloadUrlForLayer,
                           BatchCheckLayerAvailability, DescribeImages,
                           DescribeRepositories, ListImages). Default none.
    push_role_names      : IAM role NAMES in this account that may push to the
                           repository (the pull actions plus PutImage,
                           InitiateLayerUpload, UploadLayerPart, and
                           CompleteLayerUpload). Deleting is not granted: expiring
                           images is the lifecycle policy's job. Default none.
    tags                 : resource tags on the repository.

    Role names may carry a path ("service/deployer"); the module builds the ARN
    with the caller's partition and account id, so the same values deploy to any
    account in either partition. ecr:GetAuthorizationToken is a registry action
    that no repository policy can grant; the stack puts it in each role's own
    policy.

    Fixed for every repository: image tags immutable, scan on push, encryption
    with the named key, force_delete false, and prevent_destroy.
  EOT

  type = map(object({
    name                 = string
    kms_key_arn          = string
    keep_tagged_count    = optional(number, 30)
    untagged_expiry_days = optional(number, 7)
    pull_role_names      = optional(list(string), [])
    push_role_names      = optional(list(string), [])
    tags                 = optional(map(string), {})
  }))

  validation {
    condition = alltrue([
      for r in var.repositories :
      can(regex("^(?:[a-z0-9]+(?:[._-][a-z0-9]+)*/)*[a-z0-9]+(?:[._-][a-z0-9]+)*$", r.name)) && length(r.name) >= 2 && length(r.name) <= 256
    ])
    error_message = "Repository names must be 2 to 256 characters of lowercase letters, digits, hyphens, underscores, periods, and slashes, for example orders-api/prod. Each slash-separated segment starts and ends with a letter or digit, and no two separators sit next to each other."
  }

  validation {
    condition     = length(distinct([for r in var.repositories : r.name])) == length(var.repositories)
    error_message = "Repository names must be unique within the map; ECR holds one repository per name per account and region."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", r.kms_key_arn))
    ])
    error_message = "kms_key_arn must be a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<key id>), not an alias, an alias ARN, or a bare key id. ECR stores the key ARN, and anything else here would plan a change on every run. A stack passes the kms-key module's arn output; a cell never types it."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : r.keep_tagged_count >= 1 && r.keep_tagged_count <= 1000 && floor(r.keep_tagged_count) == r.keep_tagged_count
    ])
    error_message = "keep_tagged_count must be a whole number from 1 to 1000. It bounds how many images the repository holds; there is no value for \"keep everything\"."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : r.untagged_expiry_days >= 1 && r.untagged_expiry_days <= 365 && floor(r.untagged_expiry_days) == r.untagged_expiry_days
    ])
    error_message = "untagged_expiry_days must be a whole number from 1 to 365. An untagged image is a layer set a later build superseded, and a year is longer than any rollback needs."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.repositories : [
        for n in concat(r.pull_role_names, r.push_role_names) : can(regex("^([\\w+=,.@-]+/)*[\\w+=,.@-]{1,64}$", n))
      ]
    ]))
    error_message = "pull_role_names and push_role_names hold IAM role NAMES, optionally with a path such as service/deployer: letters, digits, and + = , . @ _ - per segment. \"*\" is refused because a repository policy that names every principal is a public repository, and an ARN is refused because the module builds it from the caller's account."
  }

  validation {
    condition = alltrue([
      for r in var.repositories :
      length(distinct(r.pull_role_names)) == length(r.pull_role_names) && length(distinct(r.push_role_names)) == length(r.push_role_names)
    ])
    error_message = "pull_role_names and push_role_names must not list a role twice; each name is one principal in the repository policy."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : length(setintersection(toset(r.pull_role_names), toset(r.push_role_names))) == 0
    ])
    error_message = "A role must not appear in both pull_role_names and push_role_names. Push already includes every pull action, so list a publisher once, under push."
  }
}
