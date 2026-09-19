# plan_gate

A gate for Terraform plans. It reads the JSON that `terraform show -json`
(here, `terragrunt show -json`) writes for a saved plan file and holds every
entry in `resource_changes` to a named profile: nothing but imports, nothing
at all, or nothing outside an allowlist. It is the zero-change import gate in
[`tests/README.md`](../../tests/README.md) as a program, with the two profiles
a cell needs after it has been adopted and a `report` mode that only counts.

Standard library only, Python 3.11 or later, no Terraform binary and no
network: the gate reads a file and exits 0, 1, or 2.

```
python tools/plan_gate/plan_gate.py adoption plan.json --expected-imports 3
python tools/plan_gate/plan_gate.py convergence plans/*.json --github-summary
python tools/plan_gate/plan_gate.py scoped-replace plan.json --allow 'module\.session_policy\..*'
python tools/plan_gate/plan_gate.py report plan.json --json
```

## Why a gate rather than eyeballing plans

A plan for a governance cell is a few hundred lines of attribute diff, and
the line that matters is the one that says `1 to change` under an import
block, because that is a tenant value that disagrees with the live policy and
an apply would rewrite production to match the file. A reviewer reads that
line correctly nearly every time. Nearly is not the standard for the step
that decides whether a tenant is adopted, and eyeballing is not repeatable:
the same plan read by two people on two days gets two answers, and neither
answer is recorded anywhere a later reader can check.

The workflows already count `create`, `update`, and `delete` with `jq` and
print the three numbers into the step summary. That is a report, not a gate:
it never fails the job, it does not know that an importing no-op is the
success case and an importing update is the failure case, it counts a
replace as one create and one delete, and it says nothing about drift. The
gate turns the rule the reviewer applies by hand into a program with tests,
so the rule is the same on every run, the reason for a red is one line per
address, and the plan a human approves at the subsidiary or GovCloud gate is
one a machine has already read and counted, replaces and drift included.

## Profiles

| Profile | Passes when | Use it for |
|---|---|---|
| `adoption` | every managed entry is a no-op, importing or not, and the number of importing entries equals `--expected-imports N` (or is at least `N+`) | the first plan of a cell with `imports.tf` in place |
| `convergence` | no create, update, delete, replace, or forget, and no import blocks at all | every plan of an adopted cell that should be at rest: the plan after the import apply, a nightly drift check |
| `scoped-replace` | only addresses that fully match an allowlist pattern show a change or an import; everything else is a no-op | a release that intends to replace or update named resources and nothing else |
| `report` | always | the PR summary table and the JSON a comment step reads |

Options:

- `--expected-imports N` (exactly N) or `--expected-imports N+` (at least N):
  adoption only. Without it, an adoption plan with zero imports passes with a
  warning, because a clean plan that adopted nothing usually means
  `imports.tf` was not picked up. Count the blocks in the file to get N:
  `grep -c '^import {' imports.tf`.
- `--allow REGEX` (repeatable) and `--allowlist FILE`: scoped-replace only.
  The file is a JSON list of patterns or `{"allow": [...]}`. A pattern must
  match the whole address (`re.fullmatch`), so `module.session_policy` allows
  nothing and `module\.session_policy\..*` allows the module. An
  under-specified pattern fails loudly instead of quietly allowing more than
  was meant.
- `--fail-on-drift`: drift becomes a failing finding in the three gating
  profiles. Without it drift is counted and listed but does not fail.
- `--ignore-noise`: an update whose before and after differ only by a
  trailing newline, by an empty string against null, or by map key order is
  counted as a no-op and listed under noise. An entry with any unknown value
  in `after_unknown` is never noise. The same rule applies to drift.
- `--json`: a JSON document on stdout; the human summary moves to stderr.
- `--github-summary`: append a markdown table to the file named by
  `GITHUB_STEP_SUMMARY`; a note on stderr when the variable is not set.
- `--title TEXT`: the heading of the summary and of the markdown block;
  defaults to `plan_gate <profile>`.

An option that only one profile reads is an error (exit 2) with any other
profile, not silently ignored: a gate invoked with the wrong profile must not
look as if it honoured the option.

## What is counted, and how

Each entry is classified by its `actions` array exactly as Terraform emits
it. `["no-op"]`, `["create"]`, `["update"]`, and `["delete"]` are what they
say. `["delete", "create"]` and `["create", "delete"]` are both one replace
(the second is `create_before_destroy`); neither is counted as a create plus
a delete. `["read"]` is a data source deferred to apply and is neutral, as is
anything with `mode: data`. `["forget"]` is a `removed` block and is a change.
Any other array is `unknown` and never passes a gate, because a gate that
guessed would pass an action it had never seen.

`change.importing` is counted apart from the actions. An import block whose
object agrees with the cell is an importing no-op, and that is the success
case of adoption. One that does not agree is an importing update, and that
is its failure case. Convergence refuses any import at all, because after
the first apply `imports.tf` is deleted and an import block that reappears
is a mistake.

`resource_drift` is what moved outside Terraform since the last apply. It is
counted, listed apart from the changes, and reported in its own row of the
summary. It fails a gate only with `--fail-on-drift`, because a drift that
the plan does not act on (an ignored attribute, a renewed schedule) is worth
seeing and not worth blocking a release over. A plan with `errored: true`
fails every gating profile.

The gate never prints an attribute value, an import ID, or anything from
`before` or `after`. It prints addresses, actions, and the names of the
attributes that differ, which is what a reader needs to find the cell value
to fix and nothing a step summary should carry.

## The adoption sequence it slots into

1. Export. `scripts/Import-OktaPolicies.ps1`,
   `scripts/Export-PimEligibilityImports.ps1`, or
   `scripts/Export-EntraDrift.ps1` reads the live tenant and writes
   `imports.tf` (one `import` block per object) and a values skeleton into
   the cell. The adoption hook in the family's `root.hcl` copies
   `imports.tf` into the working directory, so nothing in the stack changes.
2. Plan, saved: `terragrunt plan -input=false -out plan.tfplan` in the cell.
3. Render: `terragrunt show -json plan.tfplan > plan.json`.
4. Gate: `python tools/plan_gate/plan_gate.py adoption plan.json
   --expected-imports N`, with N the number of import blocks in
   `imports.tf`. Red means a cell value disagrees with the live object; the
   finding names the address and the attribute. Fix the cell value, never
   the module, and go back to step 2.
5. Green: `terragrunt apply plan.tfplan` records the imports and changes
   nothing in the tenant. Delete `imports.tf`. From then on the cell's plans
   are held to `convergence`, and a release that means to change something
   is held to `scoped-replace` with the addresses it means to change.

For PIM eligibilities the export has one extra first step
(`terragrunt apply -refresh-only`, see the README) and the same gate applies
afterwards.

## How the workflows call it

The runner needs nothing installed: `python3` on `ubuntu-latest` is 3.12 and
the tool has no dependencies. The three pull request workflows run a "Plan
gate" step after every plan: `convergence`, whose verdict is a step output
the comment step prints, because a pull request's plan is the change under
review and "not converged" is information for the reviewer, not a block.
One thing does block: an import block in a pull request plan. `imports.tf`
is ignored by git (`tenants/**/imports.tf` in `.gitignore`) and never
reaches a pull request checkout, so an import in a pull request plan came
from a stack's `.tf` files and would adopt a live object on merge without
the zero-change gate having read it; the step reads the import count from
the gate's JSON and fails the job when it is not zero. Exit 2 fails the job
either way. The `adoption` profile therefore runs where `imports.tf` is,
which is the workstation, at step 4 of the sequence above; the
`workflow_dispatch` job sketched below would move it to a runner and is not
in the repository yet. The AWS release train runs `report` on every plan it
takes, and the Okta and Azure trains on the merge-time plan of the gated
tenant, so the reviewer at the gate sees the replace and drift columns
(docs/adr/0018).

The shape of the report step, which replaced a jq "Summarise plan" step that
computed `add`, `change`, and `destroy` and could not see imports, replaces,
or drift. `CELL_ID` and `CELL_PATH` are the job's `env`, never a matrix
expression inside the script, so a directory name is data to the shell:

```yaml
- name: Plan summary
  run: |
    set -euo pipefail
    python3 tools/plan_gate/plan_gate.py report "$PLAN_DIR/$CELL_ID.json" \
      --github-summary --title "Azure plan: $CELL_PATH" \
      --json > "$PLAN_DIR/$CELL_ID.gate.json"
```

The merge-time plan of the gated tenant in `azure-release.yml` and
`okta-release.yml` runs that step, and so does every wave of
`aws-release.yml`; the reviewer at the gate sees the table with the replace
and drift columns the soak checklist asks about.

An adoption job on a runner would be a plan job whose gate is `adoption`,
run by `workflow_dispatch` with the cell and the expected count as inputs,
on the tenant's `<tenant>-plan` environment so it can only read. It is a
sketch, not a job the repository carries: the runner checks out `main`,
which never holds `imports.tf`, so the job also needs a way to be given the
file, and that is the decision the follow-up takes. Until then the gate runs
on the workstation that holds the file, with the same command:

```yaml
- name: Zero-change import gate
  working-directory: tenants/azure/${{ inputs.cell }}
  env:
    CELL: ${{ inputs.cell }}
    EXPECTED_IMPORTS: ${{ inputs.expected_imports }}
  run: |
    set -euo pipefail
    terragrunt plan -input=false -lock-timeout=5m -out="$PLAN_DIR/adopt.tfplan"
    terragrunt show -json "$PLAN_DIR/adopt.tfplan" > "$PLAN_DIR/adopt.json"
    python3 "$GITHUB_WORKSPACE/tools/plan_gate/plan_gate.py" adoption "$PLAN_DIR/adopt.json" \
      --expected-imports "$EXPECTED_IMPORTS" \
      --github-summary --title "adoption: $CELL"
```

A nightly convergence check is the same job on a schedule with
`convergence` in place of `adoption` and no import count; add
`--fail-on-drift` when drift should page someone rather than be read in the
morning. A release that intends a replacement carries its allowlist in the
dispatch inputs or in a JSON file beside the cell and runs
`scoped-replace --allowlist that-file.json` before the apply step, so the
apply only runs when the plan changes exactly what the release said it would.

Exit code 1 is a red gate and fails the step. Exit code 2 means the gate
could not run (the plan file is missing, is not a plan, or the options do
not fit the profile) and should be read as a workflow bug, not a tenant
problem.

## Output

The human summary is one table for every plan given, then the findings,
the allowed changes, the drift, and the ignored noise per plan, then one
`result:` line that the exit code is taken from:

```
plan_gate adoption

plan                           result  no-op  create  update  delete  replace  read  imports  drift  noise
corp-azure-rbac-roles.json     FAIL        2       0       1       0        0     1        3      0      0

plans/corp-azure-rbac-roles.json: FAIL
  - module.custom_roles.azurerm_role_definition.this["automation-runner"]: update while importing, differs on: description; the cell values disagree with the live object

result: FAIL (0 of 1 plan(s) passed)
```

`--json` writes `{tool, version, title, profile, ok, exit_code, plans: [...]}`
where each plan carries its counts, its findings, the managed entries that
were not plain no-ops (imports, changes, and ignored noise; data reads are
in the counts only), its drift, and the addresses the allowlist admitted.
`--github-summary` writes the same table as markdown under a `###` heading
and appends, so other steps' blocks in the same job are kept.

## Tests

```
python3 -m pytest tools/plan_gate/tests -q
```

On a Windows workstation where Python is not on PATH, the full path to
`python.exe` works the same.

The fixtures under `tests/fixtures/` are hand-written plan JSON in the shape
Terraform 1.9 writes (`format_version` 1.2) for the cells in this repository:
a clean adoption of three custom roles, the same with one stray update, a
converged PIM governance cell with and without drift, an Okta rule
replacement inside and outside its allowlist, both replace orderings on
Identity Center resources, and three updates that are nothing but noise.
Every profile has a passing and a failing case, every rule has both, and the
CLI is exercised end to end for exit codes, the summary, the JSON document,
and the step summary writer. The only dependency is pytest.

## What a green gate does not prove

- It does not prove the policy is a good one. It proves Terraform and the
  tenant agree.
- Attributes the provider does not track are invisible to it, as they are to
  the plan.
- A convergence pass with drift listed is a tenant that changed outside
  Terraform in a way the plan does not correct. Read the drift.
- `--ignore-noise` is a judgement that a trailing newline is not a change. It
  is right for descriptions and wrong for a policy document that is a
  string; use it per cell, not by default.
