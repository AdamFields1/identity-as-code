variable "roles" {
  description = <<-EOT
    IAM roles to manage, keyed by a stable logical name (for example
    "ci-deployer"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. Change the visible name with
    "name".

    name                 : the IAM role name. 1 to 64 characters from the IAM name
                           character set. Unique per account.
    description          : shown in the console next to the role.
    path                 : IAM path, "/" by default. Part of the role ARN.

    trust                : who may assume the role. At least one of the three forms
                           must be set; there is no input for an arbitrary principal.
      services           : service shorthands from the allowlist: "ec2", "lambda",
                           "ecs-tasks", "eks-pods". The module builds the service
                           principal for the current partition, and "eks-pods" also
                           grants sts:TagSession, which EKS Pod Identity requires.
      account_principals : 12-digit account ids for cross-account trust. Each is
                           trusted as its account principal (arn:<partition>:iam::<id>:root),
                           so that account's own IAM decides which of its roles may
                           assume this one.
      external_id        : optional sts:ExternalId the assuming account must present.
                           Only meaningful with account_principals.
      oidc_github        : GitHub Actions trust through the account's existing
                           token.actions.githubusercontent.com provider, which is
                           looked up and never created here. repository is
                           "<owner>/<repo>"; branches and environments list the
                           refs and deployment environments allowed to assume the
                           role, and at least one of the two must be non-empty.
                           No wildcard anywhere.

    aws_managed_policies      : AWS managed policy NAMES (for example
                                "AmazonSSMManagedInstanceCore" or
                                "job-function/ViewOnlyAccess"). The module builds
                                the ARN with the current partition.
    customer_managed_policies : customer managed policies that already exist in
                                this account, looked up by { name, path }.
    inline_policy             : optional IAM policy document as a JSON string, one
                                per role.
    permissions_boundary      : optional boundary. Exactly one of aws_managed_policy
                                (a policy NAME, partition-aware) or
                                customer_managed_policy ({ name, path }).
    allow_admin               : must be true to attach AdministratorAccess or
                                IAMFullAccess, or to carry an inline Allow statement
                                on Resource "*" whose actions include "*", iam:*, or
                                one of iam:PassRole, iam:AttachRolePolicy,
                                iam:PutRolePolicy, iam:CreatePolicyVersion,
                                iam:SetDefaultPolicyVersion, or
                                iam:UpdateAssumeRolePolicy, each of which is
                                administrator by privilege escalation. Default false.
    max_session_duration      : seconds, 3600 to 43200. Default 3600, the AWS
                                minimum and default.
    tags                      : resource tags on the role and its instance profile.

    A role that trusts "ec2" gets an instance profile of the same name and path.
  EOT

  type = map(object({
    name        = string
    description = optional(string, "Managed by Terraform.")
    path        = optional(string, "/")

    trust = object({
      services           = optional(list(string), [])
      account_principals = optional(list(string), [])
      external_id        = optional(string)
      oidc_github = optional(object({
        repository   = string
        branches     = optional(list(string), [])
        environments = optional(list(string), [])
      }))
    })

    aws_managed_policies = optional(list(string), [])

    customer_managed_policies = optional(list(object({
      name = string
      path = optional(string, "/")
    })), [])

    inline_policy = optional(string)

    permissions_boundary = optional(object({
      aws_managed_policy = optional(string)
      customer_managed_policy = optional(object({
        name = string
        path = optional(string, "/")
      }))
    }))

    allow_admin          = optional(bool, false)
    max_session_duration = optional(number, 3600)
    tags                 = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for r in var.roles : can(regex("^[\\w+=,.@-]{1,64}$", r.name))])
    error_message = "Role names must be 1 to 64 characters of letters, digits, and + = , . @ _ -."
  }

  validation {
    condition     = length(distinct([for r in var.roles : r.name])) == length(var.roles)
    error_message = "Role names must be unique; IAM holds one role per name per account."
  }

  validation {
    condition     = alltrue([for r in var.roles : can(regex("^/([\\w+=,.@-]+/)*$", r.path))])
    error_message = "path must start and end with a slash, for example / or /service/."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [for s in r.trust.services : contains(["ec2", "lambda", "ecs-tasks", "eks-pods"], s)]
    ]))
    error_message = "trust.services entries must be ec2, lambda, ecs-tasks, or eks-pods. The allowlist is the catalog: a service that is not on it needs a review of its own, not a free-text principal."
  }

  validation {
    condition = alltrue([
      for r in var.roles : length(r.trust.services) + length(r.trust.account_principals) + (r.trust.oidc_github == null ? 0 : 1) > 0
    ])
    error_message = "Each role must trust at least one of trust.services, trust.account_principals, or trust.oidc_github. There is no input for an arbitrary principal and none for a wildcard: a role that anyone can assume is not a shape this module offers."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [for a in r.trust.account_principals : can(regex("^[0-9]{12}$", a))]
    ]))
    error_message = "trust.account_principals holds 12-digit account ids only. \"*\" is refused because it would let every AWS account assume the role; an ARN is refused because trust is granted to an account, whose own IAM decides which of its principals may use it."
  }

  validation {
    condition = alltrue([
      for r in var.roles : r.trust.external_id == null || (
        can(regex("^[\\w+=,.@:/-]+$", coalesce(r.trust.external_id, "xx"))) && length(coalesce(r.trust.external_id, "xx")) >= 2 && length(coalesce(r.trust.external_id, "xx")) <= 1224
      )
    ])
    error_message = "trust.external_id must be 2 to 1224 characters of letters, digits, and + = , . @ : / _ - when set. No wildcard."
  }

  validation {
    condition     = alltrue([for r in var.roles : r.trust.external_id == null || length(r.trust.account_principals) > 0])
    error_message = "trust.external_id only applies to account_principals; a service or GitHub trust never presents one."
  }

  validation {
    condition = alltrue([
      for r in var.roles : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", try(r.trust.oidc_github.repository, "owner/repo")))
    ])
    error_message = "trust.oidc_github.repository must be \"<owner>/<repo>\", for example example-org/identity-as-code. No wildcard: the subject condition is built from it."
  }

  validation {
    condition = alltrue([
      for r in var.roles : r.trust.oidc_github == null || length(try(r.trust.oidc_github.branches, [])) + length(try(r.trust.oidc_github.environments, [])) > 0
    ])
    error_message = "trust.oidc_github must list at least one branch or one environment. Trusting a whole repository would be a repo:<owner>/<repo>:* subject, which is a wildcard and is refused."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [
        for v in concat(try(r.trust.oidc_github.branches, []), try(r.trust.oidc_github.environments, [])) :
        length(v) > 0 && !strcontains(v, "*") && !strcontains(v, "?")
      ]
    ]))
    error_message = "trust.oidc_github branches and environments are exact names. \"*\" and \"?\" are refused: the trust condition is StringEquals on the token subject, so a pattern would either match nothing or, with StringLike, match every branch."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [for p in r.aws_managed_policies : can(regex("^[\\w+=,.@/-]+$", p)) && !startswith(p, "arn:")]
    ]))
    error_message = "aws_managed_policies lists policy NAMES (optionally with a path prefix such as job-function/ViewOnlyAccess), never ARNs. The module adds the partition-aware ARN prefix."
  }

  validation {
    condition     = alltrue([for r in var.roles : r.allow_admin || length(setintersection(toset(r.aws_managed_policies), toset(["AdministratorAccess", "IAMFullAccess"]))) == 0])
    error_message = "AdministratorAccess and IAMFullAccess are refused unless the role sets allow_admin = true. IAMFullAccess is administrator by privilege escalation: it can attach AdministratorAccess to any role, this one included. A service role with administrative rights is a decision, not a default: the flag makes the reviewer see the word admin in the diff, next to the trust that grants it."
  }

  validation {
    condition     = alltrue([for r in var.roles : r.inline_policy == null || can(jsondecode(coalesce(r.inline_policy, "{}")))])
    error_message = "inline_policy must be a valid JSON policy document when set."
  }

  validation {
    # An Allow on Resource "*" whose actions include "*", iam:* (or any iam:
    # pattern with a wildcard in it), or one of the exact IAM actions that
    # can attach or write a policy granting everything, pass an
    # administrator role to a service, or rewrite who may assume one.
    # Actions are compared lower-cased because IAM matches them that way.
    condition = alltrue([
      for r in var.roles : r.allow_admin || r.inline_policy == null || length([
        for s in flatten([try(jsondecode(coalesce(r.inline_policy, "{}")).Statement, [])]) : s
        if try(s.Effect, "") == "Allow" && contains(flatten([try(s.Resource, [])]), "*") && length([
          for a in flatten([try(s.Action, [])]) : a
          if a == "*" || can(regex("^iam:.*\\*", lower(a))) || contains([
            "iam:passrole",
            "iam:attachrolepolicy",
            "iam:putrolepolicy",
            "iam:createpolicyversion",
            "iam:setdefaultpolicyversion",
            "iam:updateassumerolepolicy",
          ], lower(a))
        ]) > 0
      ]) == 0
    ])
    error_message = "inline_policy contains an Allow statement on Resource \"*\" whose actions include \"*\", iam:* (or an iam: pattern with a wildcard), or one of iam:PassRole, iam:AttachRolePolicy, iam:PutRolePolicy, iam:CreatePolicyVersion, iam:SetDefaultPolicyVersion, iam:UpdateAssumeRolePolicy. Each is AdministratorAccess by privilege escalation (attach or write a policy that grants everything, pass an administrator role to a service, or rewrite who may assume one) and is refused unless the role sets allow_admin = true. Scope the resource to the roles or policies the workload really needs, or set the flag so the word admin is in the diff."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [for p in r.customer_managed_policies : can(regex("^/([\\w+=,.@-]+/)*$", p.path))]
    ]))
    error_message = "customer_managed_policies path must start and end with a slash, for example / or /platform/."
  }

  validation {
    condition = alltrue([
      for r in var.roles : r.permissions_boundary == null || (
        (try(r.permissions_boundary.aws_managed_policy, null) != null) != (try(r.permissions_boundary.customer_managed_policy, null) != null)
      )
    ])
    error_message = "permissions_boundary must set exactly one of aws_managed_policy or customer_managed_policy."
  }

  validation {
    condition = alltrue([
      for r in var.roles : try(r.permissions_boundary.aws_managed_policy, null) == null || !startswith(coalesce(try(r.permissions_boundary.aws_managed_policy, null), ""), "arn:")
    ])
    error_message = "permissions_boundary.aws_managed_policy is a policy NAME, never an ARN."
  }

  validation {
    condition = alltrue([
      for r in var.roles : r.max_session_duration >= 3600 && r.max_session_duration <= 43200 && floor(r.max_session_duration) == r.max_session_duration
    ])
    error_message = "max_session_duration must be a whole number of seconds from 3600 (one hour) to 43200 (twelve hours)."
  }
}
