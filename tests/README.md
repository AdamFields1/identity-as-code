# Zero-change import gate

Adopting an existing tenant into this stack is only done when Terraform agrees with
what is already there. The rule is simple:

> After import blocks are in place, `terragrunt plan` must show **0 to add, 0 to
> change, 0 to destroy**. Until it does, the tenant is not adopted and nothing is
> applied.

This matters because an import that shows "1 to change" means the tenant values do
not match the live policy. Applying at that point would silently rewrite production
authentication settings to whatever the tenant file happens to say. The gate turns
that into a failed job instead.

## How the gate works

1. `scripts/Import-OktaPolicies.ps1` reads the live tenant and writes `imports.tf`
   (Terraform `import` blocks) and `values.skeleton.hcl` (a starting point for the
   tenant `inputs`).
2. `imports.tf` is placed in the tenant directory. `tenants/okta/root.hcl` copies it
   into the working directory through a `generate` block, so nothing in the stack
   changes.
3. `terragrunt plan -out` followed by `terragrunt show -json` produces machine-readable
   change counts. Import blocks appear in `resource_changes` with an `importing`
   object; a clean import has `actions: ["no-op"]`, a drifted one has
   `actions: ["update"]`.
4. The job fails if any count is non-zero.
5. Only after a green gate is `terragrunt apply` run. That apply writes the imported
   resources into state and changes nothing in Okta. `imports.tf` is then deleted.

## Sample GitHub Actions step

```yaml
- name: Zero-change import gate
  working-directory: tenants/okta/${{ matrix.tenant }}
  env:
    PLAN: ${{ github.workspace }}/plans/${{ matrix.tenant }}.tfplan
  run: |
    set -euo pipefail
    terragrunt plan -input=false -lock-timeout=5m -out="$PLAN"
    terragrunt show -json "$PLAN" > plan.json

    add=$(jq '[.resource_changes[]? | select(.change.actions | index("create"))] | length' plan.json)
    change=$(jq '[.resource_changes[]? | select(.change.actions | index("update"))] | length' plan.json)
    destroy=$(jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' plan.json)
    imports=$(jq '[.resource_changes[]? | select(.change.importing != null)] | length' plan.json)

    echo "add=$add change=$change destroy=$destroy imports=$imports"

    if [ "$add" != "0" ] || [ "$change" != "0" ] || [ "$destroy" != "0" ]; then
      echo "::error::Import is not zero-change (add=$add change=$change destroy=$destroy). Tenant not adopted."
      jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "\(.address): \(.change.actions | join(","))"' plan.json
      exit 1
    fi

    if [ "$imports" = "0" ]; then
      echo "::warning::No import blocks were found in this plan. Is imports.tf present?"
    fi
```

## Reading the failure

The job prints one line per drifted resource, for example:

```
module.session_policy.okta_policy_rule_signon.this["anywhere"]: update
```

Compare the plan diff for that address against the live policy and adjust the tenant
value, not the module. The module encodes the intended baseline; the tenant value
encodes what the tenant actually has. Once the two agree, the plan is empty.

## What "0 to change" does not prove

- It does not prove the policy is a good one. It proves Terraform and Okta agree.
- Attributes the provider does not track (for example a setting Okta returns but the
  resource schema ignores) are invisible to the gate.
- Rule ordering across policies not managed by this stack is not checked.
