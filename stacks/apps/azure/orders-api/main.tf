# orders-api app stack
#
# One deployable unit for one containerised application in one subscription:
# everything the container needs before it can start, and nothing it runs.
# The resource group it lives in, the identity it runs as, the identity its
# release workflow publishes as, the registry the image is pulled from, and
# the vault that holds its secrets. Order of dependency:
#
#   resource group  -->  runtime identity   (no credential; the Container App is assigned it)
#                   -->  publisher identity + GitHub federated credential
#                   -->  container registry (runtime: AcrPull; publisher: AcrPush)
#                   -->  key vault          (runtime: Key Vault Secrets User)
#
# The group comes first because everything else is created in it and looks it
# up by name. The identities come next because the two leaves grant them a
# role, and a role assignment needs a principal that exists. The leaves are
# independent of each other and Terraform applies them side by side. Every
# role in this stack is a data-plane role on the registry or the vault;
# nothing is granted on the group or through the management plane.
#
# Why this is an app stack and not a catalog cell (docs/adr/0017). Each of
# the four shapes is in the catalog, and none of them is the point: the
# application is the wiring between them. The AcrPull and the Secrets User
# are the runtime identity created two lines up, the AcrPush is the publisher
# identity created beside it, and the registry, the vault, and the
# identities are named from one pair of words so they cannot drift apart.
# That is cross-resource wiring a catalog entry cannot express, and it is
# the same composition wherever the application is deployed, so it is
# written once here and a cell says only which environment, where, and
# from which repository. A second subscription is a second cell, not a
# second stack. The AWS side of the same application
# (stacks/apps/aws/orders-api) is the same shape in that cloud's words.
#
# Two identities, because two different things act. The runtime identity is
# what the container is: it pulls the image at start-up, reads its secrets by
# name, and holds nothing that would let it change either. The publisher
# identity is what the release workflow is: it pushes an image and can do
# nothing else here, not read a secret, not touch the group. One identity
# holding both would let a compromised workflow read production secrets and
# a compromised container overwrite its own image; two identities with one
# role each make that a change to this stack instead of a consequence of it.
#
# Why the runtime identity has no federated credential. Nothing outside
# Azure obtains a token for it: the Container App is assigned the identity
# by the pipeline that deploys the app (which is not this stack), and the
# platform mints the identity's tokens for the container. A credential on
# it would be a second door into the application's secrets that no workflow
# needs. The publisher identity has exactly one credential, for one GitHub
# environment of one repository, and that is the only way anything outside
# Azure acts here.
#
# Names are derived here, never typed. rg-<app>-<env>, id-<app>-<env>,
# id-<app>-<env>-publisher, kv-<app>-<env>, and cr<app><env> (hyphens
# removed; a registry name allows none) all come from app_name and
# environment, and the validations on those two variables are what keep
# every derived name inside its service's limit: the vault's 24 characters
# is the tightest, and "kv-" + 12 + "-" + 8 fits it.
#
# What each identity may do, and no more. AcrPull reads image layers and
# manifests and nothing else; AcrPush adds push and includes pull, so the
# publisher needs one assignment, not two. Key Vault Secrets User reads
# secret values by name; it cannot list, set, or delete them, and it holds
# nothing on keys or certificates. Nothing on the management plane, for
# either identity: the Container App pulls with the runtime identity at the
# registry's login server and reads secrets at the vault's data-plane URI,
# both of which its pipeline takes from this stack's outputs, so nothing the
# container does reads a resource through ARM. A Reader on the group would
# let a compromised container list every resource and role assignment in
# it, the publisher identity included, for no call it makes. Nothing here
# can grant a management-plane role at all: the modules refuse Owner,
# Contributor, and the roles that assign roles, and this stack asks for no
# management-plane role of any kind.
#
# Two data planes, two postures. The vault is closed by default:
# public_network_access_enabled is false unless allowed_ip_ranges lists
# addresses, in which case the list opens it to exactly those addresses
# behind a Deny default. The registry's public login server is on whatever
# the SKU, because Azure keeps it on for Basic and Standard and every
# request carries an Entra token: a registry with no rule set is reachable
# by identity and by nobody without a role. Azure sells the registry
# firewall on Premium only, so the same allowed_ip_ranges is passed to the
# registry on Premium and withheld on the other two SKUs, where the module
# would refuse it (README, "Two data planes, two postures").
#
# What a cell never sees: the identities' principal IDs (wired to the
# registry and the vault as identity_principal_ids, by key), the tenant ID
# the vault is bound to (the key-vault module reads it from the provider),
# and the subscription (the locator, docs/adr/0017). No GUID exists in a
# cell.
#
# Deliberately NOT managed here: the Container Apps environment and the
# Container App (the compute is the application's pipeline's to deploy,
# roll, and scale, and it consumes this stack's outputs; README, "Consuming
# the outputs"); the Log Analytics workspace (named and resolved, never
# created); the secrets themselves (the vault starts empty, and the people
# who set the application's secrets do so with their own PIM-activated
# access, not through this stack); the images (the publisher pushes them);
# private endpoints, virtual networks, and private DNS (this repository
# manages no network); and a customer-managed key for the registry or the
# vault, which is a later change with its own key, wrap identity, and
# rotation story.

locals {
  name_suffix = "${var.app_name}-${var.environment}"

  resource_group_name     = "rg-${local.name_suffix}"
  runtime_identity_name   = "id-${local.name_suffix}"
  publisher_identity_name = "id-${local.name_suffix}-publisher"
  key_vault_name          = "kv-${local.name_suffix}"
  container_registry_name = "cr${replace(var.app_name, "-", "")}${var.environment}"

  # The GitHub environment the publisher's credential trusts: the cell's, or
  # the application's own environment name when the cell does not say.
  publisher_github_environment = coalesce(var.publisher_github_environment, var.environment)

  # The vault's public access is a consequence of listing addresses, never a
  # separate switch a cell could leave on with an empty list.
  vault_public_network_access_enabled = length(var.allowed_ip_ranges) > 0

  # The registry firewall exists on Premium only, and the module refuses a
  # list on any other SKU, so the list reaches the registry only when the
  # SKU can carry it. On Basic and Standard the registry is reachable by
  # identity from anywhere, which is Azure's posture for those SKUs, not a
  # choice this stack makes.
  registry_allowed_ip_ranges = var.registry_sku == "Premium" ? var.allowed_ip_ranges : []

  # Every resource carries the application's name and environment; the
  # cell's own tags are merged over them.
  tags = merge(
    {
      application = var.app_name
      environment = var.environment
    },
    var.tags,
  )
}
