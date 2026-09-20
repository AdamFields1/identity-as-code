# Zero-change import gate

Adopting an existing tenant into this stack is only done when Terraform agrees with
what is already there. The rule is simple:

> After import blocks are in place, `terragrunt plan` must show **0 to add, 0 to
> change, 0 to destroy**. Until it does, the tenant is not adopted and nothing is
> applied.

This matters because an import that shows "1 to change" means the tenant values do
not match the live policy. Applying at that point would silently rewrite production
authentication settings to whatever the tenant file happens to say. The gate turns
that into a failed run instead: exit 1 on the workstation that holds `imports.tf`,
where adoption happens, and a red job wherever the same command runs in a workflow.

The gate is a program, [`tools/plan_gate`](../tools/plan_gate/README.md). It reads
the plan JSON, knows that an importing no-op is the success case and an importing
update is the failure case, counts a replace as one replace, reports drift apart
from changes, and exits 1 with one line per offending address. Its README covers
the other profiles a cell needs after adoption (`convergence`, `scoped-replace`)
and where the workflows call it.

## How the gate works

1. `scripts/Import-OktaPolicies.ps1` reads the live tenant and writes `imports.tf`
   (Terraform `import` blocks) and `values.skeleton.hcl` (a starting point for the
   tenant `inputs`).
2. `imports.tf` is placed in the cell directory (`tenants/okta/<tenant>/okta-config`).
   `tenants/okta/root.hcl` copies it into the working directory through a `generate` block, so nothing in the stack
   changes.
3. `terragrunt plan -out` followed by `terragrunt show -json` produces machine-readable
   change counts. Import blocks appear in `resource_changes` with an `importing`
   object; a clean import has `actions: ["no-op"]`, a drifted one has
   `actions: ["update"]`.
4. `plan_gate adoption` reads that JSON. The run fails if any entry is not a no-op,
   or if the number of imports is not the number of blocks in `imports.tf`.
5. Only after a green gate is `terragrunt apply` run. That apply writes the imported
   resources into state and changes nothing in Okta. `imports.tf` is then deleted,
   and from then on the cell's plans are held to `plan_gate convergence`.

## Sample GitHub Actions step

This is the shape of a `workflow_dispatch` adoption job, not a job the repository
carries. `imports.tf` is ignored by git (`tenants/**/imports.tf`), so a runner's
checkout never holds it and the job would first need a way to be given the file;
that is a follow-up. Until then step 4 runs on the workstation, with the same
command and the same exit codes. The pull request workflows hold every plan to
`convergence` and fail the job on any import block, so an import cannot reach a
release train without this gate having passed first.

```yaml
- name: Zero-change import gate
  working-directory: tenants/okta/${{ matrix.tenant }}/okta-config
  env:
    TENANT: ${{ matrix.tenant }}
    PLAN: ${{ github.workspace }}/plans/${{ matrix.tenant }}.tfplan
    EXPECTED_IMPORTS: ${{ inputs.expected_imports }}
  run: |
    set -euo pipefail
    terragrunt plan -input=false -lock-timeout=5m -out="$PLAN"
    terragrunt show -json "$PLAN" > plan.json
    python3 "$GITHUB_WORKSPACE/tools/plan_gate/plan_gate.py" adoption plan.json \
      --expected-imports "$EXPECTED_IMPORTS" \
      --github-summary --title "adoption: okta/$TENANT"
```

The tool needs Python 3.11 or later and nothing outside the standard library,
which every GitHub-hosted runner has. Exit code 1 is a red gate; exit code 2 means
the plan file could not be read and is a workflow bug, not a tenant problem.
`--expected-imports` takes an exact count, or `N+` for at least N; without it a
plan with no imports passes with a warning that `imports.tf` may be missing.

## The same gate in shell

The gate the workflows carried before the tool, kept here because it is the whole
rule in a dozen lines of `jq` and shows what the tool is checking. It does not
count imports against an expectation, does not tell an importing no-op from a
plain one, and counts a replace as a create and a delete.

```yaml
- name: Zero-change import gate (jq)
  working-directory: tenants/okta/${{ matrix.tenant }}/okta-config
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

The tool prints one line per drifted resource, for example:

```
- module.session_policy.okta_policy_rule_signon.this["anywhere"]: update while importing, differs on: session_idle; the cell values disagree with the live object
```

Compare the plan diff for that address against the live policy and adjust the tenant
value, not the module. The module encodes the intended baseline; the tenant value
encodes what the tenant actually has. Once the two agree, the plan is empty.

## After adoption

With `imports.tf` deleted and the import apply recorded, the same plan JSON is held
to `plan_gate convergence`: no changes and no import blocks. Drift that the plan
does not act on is listed apart from the changes and does not fail the gate unless
`--fail-on-drift` is given. A release that means to replace a resource runs
`plan_gate scoped-replace` with the addresses it means to change, so the apply
only proceeds when the plan changes exactly those.

## What "0 to change" does not prove

- It does not prove the policy is a good one. It proves Terraform and Okta agree.
- Attributes the provider does not track (for example a setting Okta returns but the
  resource schema ignores) are invisible to the gate.
- Rule ordering across policies not managed by this stack is not checked.
