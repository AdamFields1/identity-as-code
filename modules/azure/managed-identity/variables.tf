variable "identities" {
  description = <<-EOT
    User-assigned managed identities to manage, keyed by a stable logical name
    (for example "ci-deploy"). The key is part of the Terraform address, and it
    is also what the key-vault and storage-account modules accept as a principal
    (principal = { type = "identity", name = "<key>" }), so it should never change
    once applied. Change the visible name with "name".

    name                  : the identity's name in Azure, which is also its
                            service principal's display name in Entra. 3 to 128
                            letters, digits, hyphens, and underscores, starting
                            with a letter or digit. Immutable.
    resource_group_name   : existing resource group, by name. Looked up, never
                            created here.
    location              : Azure region. Null (default) uses the resource
                            group's location.
    tags                  : tags on the identity, merged over the module-level
                            tags; the entry wins per key.
    federated_credentials : GitHub Actions federated credentials keyed by a
                            stable name. Each names one workflow context that
                            may obtain a token for this identity, and nothing
                            else can; no secret exists. The subject is built
                            here, never typed:
        organization : the GitHub organization (or user) that owns the repository.
        repository   : the repository name, without the organization.
        branch       : a branch; the subject becomes
                       repo:<organization>/<repository>:ref:refs/heads/<branch>.
        environment  : a GitHub environment; the subject becomes
                       repo:<organization>/<repository>:environment:<environment>.
                       Exactly one of branch or environment.
        issuer       : the token issuer. Default https://token.actions.githubusercontent.com
                       (GitHub.com); a GitHub Enterprise Server has its own.
        audience     : default api://AzureADTokenExchange, which is what the
                       azure/login action requests.
        name         : the credential's name in Azure. Default: the map key.
  EOT

  type = map(object({
    name                = string
    resource_group_name = string
    location            = optional(string)
    tags                = optional(map(string), {})

    federated_credentials = optional(map(object({
      organization = string
      repository   = string
      branch       = optional(string)
      environment  = optional(string)
      issuer       = optional(string, "https://token.actions.githubusercontent.com")
      audience     = optional(string, "api://AzureADTokenExchange")
      name         = optional(string)
    })), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for i in var.identities : can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$", i.name))])
    error_message = "Every identity name must be 3 to 128 letters, digits, hyphens, and underscores, starting with a letter or digit."
  }

  validation {
    condition     = length(distinct([for i in var.identities : lower(i.name)])) == length(var.identities)
    error_message = "Two entries have the same identity name. The name is also the service principal's display name in Entra, so keep it unique."
  }

  validation {
    condition     = alltrue([for i in var.identities : length(trimspace(i.resource_group_name)) > 0])
    error_message = "resource_group_name must not be empty."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for c in i.federated_credentials : (c.branch != null) != (c.environment != null)]
    ]))
    error_message = "Every federated credential must set exactly one of branch or environment; the subject is built from whichever is set."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for c in i.federated_credentials : can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", c.organization))]
    ]))
    error_message = "organization must be a GitHub organization or user name: letters, digits, and hyphens, starting with a letter or digit, 39 characters or fewer."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for c in i.federated_credentials : can(regex("^[A-Za-z0-9_.-]{1,100}$", c.repository))]
    ]))
    error_message = "repository must be a GitHub repository name without the organization: letters, digits, periods, hyphens, and underscores."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [
        for c in i.federated_credentials :
        c.branch == null || (can(regex("^[^\\s~^:?*\\[\\\\]+$", coalesce(c.branch, "-"))) && !strcontains(coalesce(c.branch, "-"), ".."))
      ]
    ]))
    error_message = "branch must be a single branch name with no wildcard: Entra matches the subject exactly, so a pattern such as release/* would never match a token."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for c in i.federated_credentials : c.environment == null || length(trimspace(coalesce(c.environment, " "))) > 0]
    ]))
    error_message = "environment must not be empty when set."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for c in i.federated_credentials : can(regex("^https://", c.issuer))]
    ]))
    error_message = "Federated credential issuer must be an https URL."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for c in i.federated_credentials : length(trimspace(c.audience)) > 0]
    ]))
    error_message = "Federated credential audience must not be empty."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [for key, c in i.federated_credentials : can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,119}$", coalesce(c.name, key)))]
    ]))
    error_message = "Every federated credential name (the map key unless name is set) must be 3 to 120 letters, digits, hyphens, and underscores, starting with a letter or digit."
  }

  validation {
    condition = alltrue([
      for i in var.identities :
      length(distinct([for key, c in i.federated_credentials : lower(coalesce(c.name, key))])) == length(i.federated_credentials)
    ])
    error_message = "Two federated credentials on the same identity have the same name."
  }

  validation {
    condition = alltrue([
      for i in var.identities :
      length(distinct([
        for c in i.federated_credentials :
        "${c.issuer}|${c.organization}/${c.repository}|${c.branch == null ? "" : c.branch}|${c.environment == null ? "" : c.environment}"
      ])) == length(i.federated_credentials)
    ])
    error_message = "Two federated credentials on the same identity describe the same GitHub context (issuer, organization, repository, and branch or environment). Entra refuses a duplicate subject, so merge them."
  }
}

variable "tags" {
  description = "Tags applied to every identity. An entry's own tags are merged over these."
  type        = map(string)
  default     = {}
}
