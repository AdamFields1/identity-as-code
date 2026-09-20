# Subscription locator for tenants/azure/corp/subscriptions/sub-example-dev/.
#
# Not a cell: no include, no source, no inputs, and Terragrunt never runs it.
# Every cell in this directory is addressed to this subscription.
# tenants/azure/root.hcl reads subscription_id and passes it to the azurerm
# provider in place of ARM_SUBSCRIPTION_ID. The tenant still comes from
# ARM_TENANT_ID, because the tenant is the tree (corp/), not a locator. No
# cell below this file repeats the id. See docs/adr/0017.
#
# subscription_name must equal this directory's name; the root refuses a
# mismatch, which is what catches a locator copied from a neighbouring
# subscription (this one began as a copy of ../sub-example-prod) and left
# unedited. It is the same display name the platform stacks resolve by
# name.

locals {
  subscription_id   = "22222222-2222-2222-2222-222222222222"
  subscription_name = "sub-example-dev"
}
