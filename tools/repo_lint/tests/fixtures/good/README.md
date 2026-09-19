# fixture: good tree

A miniature identity-as-code layout that satisfies every repo_lint check.
Every name and id is a placeholder; the estate contact is iam@corp.example.com,
the runbooks call graph.microsoft.com, and the Owner role id
8e3af657-a8ff-443c-a75c-2fe8c4bcb635 is a published constant.

## What it manages

| Object | Module |
|--------|--------|
| Network zones | `modules/okta/network-zone` |
| Custom role definitions | `modules/azure/rbac-role-definition` |
| PIM role policies | `modules/azure/pim-role-policy` |
| Runbooks published from files | `modules/azure/automation-runbooks` |
| Resource groups | `modules/azure/resource-group` |
| Conditional Access policies | `modules/entra/conditional-access` |
| Permission sets | `modules/aws/permission-set` |
| Customer managed keys | `modules/aws/kms-key` |
| Buckets under a named key | `modules/aws/s3-bucket` |

| Stack | Cells |
|-------|-------|
| `stacks/okta-config` | `tenants/okta/{dev,prod}` |
| `stacks/azure-rbac-roles` | `tenants/azure/corp/azure-rbac-roles` |
| `stacks/azure-pim-governance` | `tenants/azure/{corp,subsidiary}/azure-pim-governance` |
| `stacks/azure-automation` | `tenants/azure/corp/azure-automation` |
| `stacks/entra-conditional-access` | `tenants/azure/{corp,subsidiary}/entra-conditional-access` |
| `stacks/azure-subscription-baseline` | `tenants/azure/corp/subscriptions/sub-example-prod/azure-subscription-baseline` |
| `stacks/azure-subscription-workloads` | `tenants/azure/corp/subscriptions/sub-example-prod/azure-subscription-workloads` |
| `stacks/apps/azure/data-pipeline` | `tenants/azure/corp/subscriptions/sub-example-prod/data-pipeline` |
| `stacks/aws-identity-center` | `tenants/aws/{commercial,govcloud}/aws-identity-center` |
| `stacks/aws-account-baseline` | `tenants/aws/commercial/accounts/{example-prod,example-dev}/aws-account-baseline` |
| `stacks/aws-account-workloads` | `tenants/aws/commercial/accounts/example-prod/aws-account-workloads` |
| `stacks/apps/aws/payments-api` | `tenants/aws/commercial/accounts/example-prod/payments-api` |

The AWS access group for the prod account is AWS-COM-111111111111-Admin and
the SCIM token reaches Terraform as `secret_token = "CHANGEME"`, never a file.

## Layout

```
identity-as-code/
  modules/
    okta/                       network-zone
    azure/                      rbac-role-definition, pim-role-policy, automation-runbooks,
                                resource-group
    aws/                        permission-set, kms-key, s3-bucket
  stacks/                       units of deployment
    okta-config/
    apps/                       app stacks (docs/adr/0002)
      aws/payments-api/
      azure/data-pipeline/
  automation/
    runbooks/                   one example runbook
    lib/                        shared runbook plumbing
  policies/
    azure/pim-governance/       the Azure PIM baseline
  tenants/
    okta/
      root.hcl                  state and provider generation
      dev/terragrunt.hcl
      prod/terragrunt.hcl
    azure/
      root.hcl
      corp/
        azure-rbac-roles/terragrunt.hcl
        subscriptions/          subscription-scoped cells
          sub-example-prod/
            subscription.hcl    locator: subscription id and name; not a cell
            data-pipeline/terragrunt.hcl
    aws/
      root.hcl
      commercial/
        partition.hcl           locator: ARN partition and default region
        accounts/
          example-prod/
            account.hcl         locator: account id and name
            payments-api/terragrunt.hcl
  docs/                         decision records
```
