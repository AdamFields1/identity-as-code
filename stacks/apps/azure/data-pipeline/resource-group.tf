# ---------------------------------------------------------------------------
# The resource group. Everything below is created in it and looks it up by
# name, so the modules below carry depends_on on this one: Terraform then
# reads the group during apply on the first run, when it does not exist at
# plan time, and at plan time on every run after.
# ---------------------------------------------------------------------------

module "resource_groups" {
  source = "../../../../modules/azure/resource-group"

  tags = local.tags

  resource_groups = {
    app = {
      name        = local.resource_group_name
      location    = var.location
      delete_lock = var.delete_lock
    }
  }
}
