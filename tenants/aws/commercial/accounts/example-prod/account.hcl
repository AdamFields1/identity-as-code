# Account locator for tenants/aws/commercial/accounts/example-prod/.
#
# Not a cell: no include, no source, no inputs, and Terragrunt never runs it.
# Every cell in this directory is addressed to this account. tenants/aws/root.hcl
# reads account_id and sets allowed_account_ids so a plan whose credentials
# land anywhere else stops before its first resource API call, and reads
# account_name to give the provider the profile identity-as-code-example-prod,
# in which the workflow (or an engineer) names the deployment role
# arn:aws:iam::111111111111:role/<TG_AWS_DEPLOY_ROLE_NAME>; the role is in no
# generated file. No cell below this file repeats the id. See docs/adr/0017.
#
# account_name must equal this directory's name; the root refuses a mismatch,
# which is what catches a locator copied from a neighbouring account and left
# unedited. The id is the same one the commercial Identity Center cell carries
# in its AWS-COM-111111111111-* group names.

locals {
  account_id   = "111111111111"
  account_name = "example-prod"
}
