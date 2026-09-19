# ADR 0018: CI and repository tooling is Python; runbooks stay PowerShell

Status: accepted
Date: 2026-09-19

## Context

Three kinds of logic had grown inside the workflows and the READMEs with
nothing to run them but a reviewer's memory.

The first is plan arithmetic. Every plan job counted `create`, `update`, and
`delete` with `jq` and printed three numbers into the step summary. That is
a report, not a gate: it never failed a job, it did not know that an
importing no-op is the success case of an adoption and an importing update
is its failure case, it counted a replace as one create and one delete, and
it said nothing about drift. The zero-change import gate in
`tests/README.md`, the rule this repository adopts tenants by, existed as a
paragraph and a dozen lines of `jq` that a workflow could copy.

The second is path logic. Each pull request workflow carried its own shell
that found cells with `find tenants/<cloud> -name terragrunt.hcl` and
decided which of them a change touches, and each release train restated the
order of the cells as one hand-written plan and apply job per cell, with the
same order drawn once more in its header comment. ADR 0017 named the cost:
"a new cell also needs its two jobs added there." Three copies of one piece
of knowledge, and a fourth in prose.

The third is the rules the repository states about itself. "A cell contains
exactly three things." "Every name, CIDR, and ID in it is a placeholder."
"No `[switch]`, and no `[string[]]`, on a parameter a schedule sets." "Every
module and stack is named in the README." Each is written down; none was
checked by anything but a reader.

The runbooks are a different case. They run inside Azure Automation, on a
sandbox that offers PowerShell and nothing the repository chooses, and on a
Hybrid Runbook Worker that may be Windows PowerShell 5.1 (ADR 0010). Their
language is not a decision this repository gets to make.

Three ways to give the CI logic a home were considered.

**More shell and `jq`.** The counting is already there; the gate could be
fifty more lines of it. Shell has no tests here, `jq` programs do not carry
their reasons, and the path logic (walk a tree, read a Terragrunt file,
follow `source` lines, order by dependency) is the kind of thing shell does
badly and silently.

**PowerShell, like the runbooks.** One language for everything the
repository runs. But `ubuntu-latest` is where the Terraform jobs run, and
putting `pwsh` steps beside `terragrunt` steps to read JSON that Python
reads with nothing installed is a second runtime for no gain. The runbook
library's plumbing (tokens, paging, retries, mail, a breaker) is exactly
what a CI tool does not need.

**Python, standard library only.** Every GitHub-hosted runner has Python
3.12. `json`, `re`, `pathlib`, `argparse`, and `subprocess` cover plan JSON,
HCL scanning, path logic, a CLI with `--help`, and `git diff --name-only`
without a dependency. The tests run under `pytest`, which the lint job
installs beside the optional `python-hcl2` cross-check, and they need no
network and no Terraform binary.

## Decision

The CI and repository-tooling layer is Python 3.11 or later, standard
library only, under `tools/`. The runbooks, the runbook libraries, and the
scripts that run against a tenant stay PowerShell.

The boundary is where the code runs. A tool runs on a GitHub runner or a
workstation and reads files: plan JSON, Terragrunt files, the README, the
decision records. A runbook runs in Azure Automation and reads a tenant. A
script under `scripts/` runs on a workstation or a runner against a tenant,
and stays PowerShell because it shares a library with a runbook (ADR 0013).

**`tools/plan_gate`** reads the JSON that `terraform show -json` writes for
a saved plan and holds every entry in `resource_changes` to a profile:
`adoption` (every entry a no-op, importing or not, and the import count
matching `imports.tf`), `convergence` (no change and no import at all),
`scoped-replace` (only allowlisted addresses may change), or `report` (the
table only). It counts a replace as one replace, lists drift apart from
changes, prints addresses and attribute names and never a value, and exits
0, 1, or 2. The pull request workflows run `convergence` after every plan,
whose verdict goes into the step summary and the pull request comment, and
fail the job on any import block, because `imports.tf` is ignored by git and
an import in a pull request plan is one the zero-change gate has not read.
`adoption` runs where `imports.tf` is, on the workstation at step 3 of the
adoption sequence, so the zero-change import gate is a program with tests
rather than a paragraph; a `workflow_dispatch` job that runs it on a runner
is sketched in the tool's README and is a follow-up. The AWS release train
runs `report` on every plan it takes, and the Okta and Azure trains on the
merge-time plan the reviewer approves at the gate.

**`tools/repo_lint`** holds two programs. `repo_lint.py` checks the tree
against eight rules the README and the decision records state, one named
check each with the sentence it comes from in its docstring, and runs on
every pull request and push to `main` (`.github/workflows/repo-lint.yml`).
`cells.py` discovers the tenant cells, works out which ones a change
touches, and orders the selected cells into waves from the rules the trains
already state: a Terragrunt `dependencies` block; baseline, then catalog,
then app stacks inside an account or subscription; definitions before the
cells that resolve them by name; tenant-wide before scoped; the first tenant
before the gated one. The AWS release train reads that matrix instead of
listing its cells.

Every tool has type hints on every function, a module docstring that states
its contract and exit codes, an `argparse` interface with `--help`, and a
test suite whose fixtures are small JSON or HCL files under the tool's
`tests/fixtures`, with at least one passing and one failing fixture per
rule. The tests never touch the network and never run Terraform. A tool
never prints a secret, a token, an import ID, or an attribute value.

## Why the repository lints its own rules

A rule that lives only in prose is enforced at review time by whoever
remembers it, and the README already holds more sentences of that kind than
a reviewer keeps in mind. Turning each into a check with the sentence in its
docstring does three things. The rule is applied the same way on every pull
request. The finding says which sentence it violates and where. And the
sentence and the check are diffed together, so a rule that changes has to
change in both places, and a check nobody can attribute to a sentence is a
check to delete.

The first run proved the point in the smallest way. Two runbooks carried a
`[string[]]` parameter that no schedule set, and the automation README had
excepted one of them in a sentence. The fix was to make both parameters
what the rule says, semicolon strings parsed like every other list, and to
drop the exception, not to teach the check about it: a top-level array
parameter is a binding failure waiting for the first cell that sets it,
whether or not one does today.

## Why the plan gate exists

A plan for a governance cell is a few hundred lines of attribute diff, and
the line that matters at adoption is the one that says `1 to change` under
an import block, because that is a tenant value that disagrees with the live
policy and an apply would rewrite production to match the file. A reviewer
reads that line correctly nearly every time. Nearly is not the standard for
the step that decides whether a tenant is adopted, and eyeballing is not
repeatable: the same plan read by two people on two days gets two answers,
and neither answer is recorded anywhere a later reader can check. The gate
is the same rule as a program with tests, so the verdict is the same on
every run, the reason for a red is one line per address, and the plan a
human approves at the subsidiary or GovCloud gate is one a machine has
already read and counted, replaces and drift included.

## Consequences

- **A third language in the repository, with a fence around it.** HCL for
  what is declared, PowerShell for what runs against a tenant, Python for
  what runs in CI and reads the repository. A Python file outside `tools/`,
  or a tool that imports something outside the standard library at run
  time, is a review question, not a convenience.
- **The tools are tested; the workflows are wiring.** A workflow can only be
  run by GitHub. Moving the logic into tools moves it to where `pytest` can
  reach it, and leaves the workflows as install, plan, call the tool,
  upload. The wiring is still reviewed by reading, and the README's
  verification status says so.
- **The convergence verdict on a pull request is a report, not a block; an
  import block in one is.** A pull request's plan is the change under
  review, so a plan that changes the tenant is the expected case; a
  convergence red is written into the summary and the comment, and the
  reviewer decides. An import block in a pull request plan fails the job
  outright, because imports are adopted from a workstation through
  `imports.tf` behind the adoption gate, and that gate blocks wherever it
  runs, because a red there is the zero-change rule. A release that means
  to change named resources and nothing else runs `scoped-replace`, and a
  nightly check that should page runs `convergence --fail-on-drift`.
- **`cells.py` is the release order for AWS; the Azure train is a
  follow-up.** The AWS train applies what the matrix says, in waves, and a
  new AWS cell needs no workflow edit; ADR 0017's "one hardcoded plan and
  apply job per cell" is no longer true of it. The Azure train still lists
  its cells by hand, on purpose: it carries a job that is not a cell (the
  authentication methods policy, ADR 0012) at a fixed point in the order,
  and it deliberately leaves out cells the matrix would include (the
  federation cell, whose SCIM credentials the workflows do not yet map, ADR
  0008; the Entra cells, which the train has never released). Switching
  the matrix on there would release them by accident. Each is a decision to
  take in its own pull request.
- **Two runtimes on the runners, still.** The Terraform jobs are shell
  around `terragrunt` and now call `python3`; the automation tests are
  PowerShell on `windows-latest`. Nothing was gained by pretending
  otherwise, and each job installs only what it runs.
- **`python-hcl2` is not a dependency.** One test cross-checks the tools'
  HCL scanner against it when it is installed; the lint workflow installs it
  so the cross-check runs, and a workstation without it skips that one test
  and nothing else changes. The scanner is the parser on purpose, because
  the library's output shape has changed between major versions and the
  four things the tools read from a file do not need a grammar.
