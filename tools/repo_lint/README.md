# repo_lint

The rules this repository writes down about itself, enforced by a program
instead of by a reviewer's memory. Two tools, standard-library Python 3.11
or later, no runtime dependency, no network, no Terraform binary:

- `repo_lint.py` checks the tree against nine rules the README and the
  decision records state. Each rule is one named check with the sentence or
  ADR it comes from in its docstring, so `--list-checks` is the index.
- `cells.py` discovers the tenant cells, works out which ones a change
  touches, and orders the selected cells into waves, which is what the AWS
  and Okta release trains read and the Azure train still states with one
  hand-written job per cell (ADR 0018).

Both exit 0 when there is nothing to say, so they can sit in a workflow
next to `terraform fmt` and `tflint`, and do: `.github/workflows/repo-lint.yml`
runs both test suites, `repo_lint.py`, and `cells.py --all` on every pull
request and push to `main`.

## The checks

| Check | What it enforces | Where the rule is written |
|-------|------------------|---------------------------|
| `cell-shape` | Every `tenants/**/terragrunt.hcl` holds an `include` of the family root, a `terraform` block whose `source` is a literal path to a directory under `stacks/` that exists, an `inputs` attribute, and optionally a `dependencies` block whose every path is a literal relative path to a directory under `tenants/` that holds a `terragrunt.hcl`. A cell may carry more than one `include`: then every include is labeled, exactly one include's path is `find_in_parent_folders("root.hcl")` (under any label), and every other include names a fragment, a sibling `.hcl` file by its bare name (no directory, no template, never `terragrunt.hcl`), that exists beside the cell. A `resource`, `data`, `module`, `locals`, `variable`, `output`, `provider`, or any other block is refused with the reason. Its directory names are letters, digits, dot, hyphen, and underscore only, because the workflows use a cell's path as a job name and a shell word, and its tenant is one the family's promotion order in `cells.py` names, because the release trains name their GitHub environments from it. | README, Three layers: "Each cell is one stack applied for one tenant, and it contains exactly three things: an include of the shared root, a source pointing at the stack, and an inputs map of values. No resources, no data sources, no conditionals, no IDs. A cell calls a stack, never a module." ADR 0002; ADR 0017, "a cell never holds a resource block, a data source, a conditional, or a module call". ADR 0018 and the header of `aws-release.yml` for the two rules about where a cell sits. |
| `fragment-shape` | Every `.hcl` file beside a `terragrunt.hcl` under `tenants/` other than the cell itself is a fragment: it parses, holds exactly one top-level `inputs` attribute and nothing else (no `include`, `terraform`, `locals`, `dependencies`, `dependency`, `generate`, `resource`, or any other block or attribute), and is named by one of the cell's `include` blocks. A fragment is values only, like the cell it belongs to: it is how a catalog cell reads like the console, one file per map (`iam-roles.hcl`, `kms-keys.hcl`, `s3-buckets.hcl`) with the comments that explain the entries beside them, and Terragrunt merges every include's `inputs` into the one map the stack sees. A fragment nobody includes is dead values and is refused. | README, Three layers, and ADR 0002: the cell is values only, and a file the cell merges into its inputs is held to the same rule. The catalog cells' header comments state the contract: "a fragment is not a cell: no include, no source, and Terragrunt never runs it on its own". |
| `locators` | `tenants/aws/<partition>/partition.hcl` has `partition` in `aws` or `aws-us-gov` and a `region` in that partition; `accounts/<name>/account.hcl` has a 12-digit `account_id` and an `account_name` equal to its directory; `tenants/azure/<tenant>/subscriptions/<name>/subscription.hcl` has a lower-case GUID `subscription_id` and a `subscription_name` equal to its directory. A locator holds one `locals` block of quoted literals and nothing else, sits at exactly that level, and every partition, account, and subscription directory has one. | ADR 0017, "Account IDs and subscription IDs are addressing, not configuration" and "Both roots refuse a locator whose ID is malformed and a locator whose name does not equal the name of the directory it sits in." The roots' own guards (`tenants/aws/root.hcl`, `tenants/azure/root.hcl`) are the same rules at `terragrunt init`; this check runs them without Terragrunt. |
| `placeholders` | Every 12-digit run is one repeated digit; every GUID is one repeated digit, all zeros, or an id listed in `microsoft_builtin_ids.txt`; every hostname is under a documentation domain (`example.com`, `example.org`, `example.net`) or an endpoint or documentation host of a vendor the repository talks to (Microsoft, AWS, Okta, GitHub, HashiCorp, Google Workspace) or the SAML claim-type namespace (`xmlsoap.org`), listed one domain at a time in `VENDOR_DOMAINS` from what the tree uses; every email address is under a documentation domain. | README: "Every name, CIDR, and ID in it is a placeholder." |
| `ascii` | Every text file is plain ASCII. An em dash (U+2014), an en dash (U+2013), and a UTF-8 byte order mark get their own message; everything else reports file, line, column, and code point. Files with a NUL byte are treated as binary and skipped. | Repository convention: `.editorconfig` fixes the encoding, and the runbooks run on Windows PowerShell 5.1, where a non-ASCII byte in a script file depends on the codepage the job happens to have (ADR 0010). |
| `no-secrets` | No credential with a shape of its own, anywhere in the tree: an AWS access key id, a private key block, a JWT (two base64url JSON objects and a signature, so both of its first segments start with `eyJ`), an Okta `SSWS` header or 42-character `00` API token, a GitHub classic or fine-grained token, an Azure client secret (`8Q~` at offset 3), a storage account key (`AccountKey=`), a Service Bus key (`SharedAccessKey=`), a SAS signature (`sig=`), or a Slack webhook. And no assignment of a secret-named variable (`secret`, `password`, `passwd`, `api_key`, `apikey`, `token`, `credential`, `private_key`, `access_key`, `account_key`, `connection_string`, or `sas`, as the name or part of it) to a quoted literal longer than six characters or to a bare word of twelve or more (a shell export, an INI file, unquoted HCL). A reference (`var.x`, `local.a.b`), a variable or an expansion (`$token`, `"Bearer $token"`), a cmdlet (`Get-RunbookAccessToken`), an identifier or word with no digit, a quoted environment variable name (`'OKTA_API_TOKEN'`), a URL, a path, and the obvious placeholders (`CHANGEME`, `example`, `<paste here>`, `${var.x}`) are not literals. The shaped detectors read every file; the assignment heuristic skips test files (`tests/`, `test/`, `__tests__/`, `*.Tests.ps1`, `test_*.py`, `*_test.py`), which assign stand-in tokens by construction. The finding names the pattern, never the match. | ADR 0003, No long-lived secrets in CI; README: the Okta token "is never written to a generated file, a plan artifact, or state", and the SCIM token "reaches Terraform as a sensitive `TF_VAR` from a GitHub environment secret and appears in no file". |
| `readme-tables` | Every directory under `modules/<provider>/` and every stack directory (anything under `stacks/` holding a `.tf` file, so `stacks/apps/<cloud>/<app>` counts and `stacks/apps` does not) is named in `README.md`, and every path the README Layout tree names exists. | README, What it manages ("Nine platform stacks compose those modules ... Six more stacks are scoped") and Layout. |
| `runbook-params` | Every `automation/runbooks/*.ps1` has no `[switch]` and no array-typed parameter (`[string[]]` or any `[type[]]`) in its top-level `param` block, and never calls `Write-Host`. Nested functions may take arrays: they are called from code, not from a schedule. Strings, comments, and here-strings are blanked before matching. | README, Verification status: "that `[bool]` parameters bind from the job schedule strings" and "that every semicolon list arrived whole and split into the expected number of entries ... rather than as one space-joined string"; ADR 0010. A job schedule carries strings, numbers, and booleans; a switch or an array on a scheduled runbook fails at binding. |
| `adr-index` | Every `docs/adr/NNNN-*.md` has a `Status:` line and a `Date: YYYY-MM-DD` line in its first thirty lines, its title says the same number as its file name, and the numbers run from 0001 with no gap and no duplicate. | README, History: "The decision records carry the reasoning that the commits do not." An index with a hole is a decision nobody can find. |

### Finding codes

Every finding carries a stable code, so a workflow or a test can match on it
without parsing the message.

- `cell-shape`: `forbidden-block`, `missing-include`, `missing-terraform`,
  `missing-inputs`, `missing-source`, `source-not-static`,
  `source-not-under-stacks`, `source-missing`, `duplicate-block`,
  `inputs-not-attribute`, `not-a-block`, `parse-error`, `path-characters`,
  `tenant-unknown`, `dependencies-paths-missing`, `dependency-not-static`,
  `dependency-outside-tenants`, `dependency-missing`, `include-unlabeled`,
  `include-root-missing`, `include-root-duplicate`, `fragment-include-path`,
  `fragment-missing`.
- `fragment-shape`: `fragment-parse-error`, `fragment-forbidden-block`,
  `fragment-missing-inputs`, `fragment-not-included`.
- `locators`: `partition-invalid`, `partition-region-missing`,
  `partition-region-invalid`, `partition-region-mismatch`,
  `account-id-invalid`, `account-name-mismatch`, `subscription-id-invalid`,
  `subscription-name-mismatch`, `locator-extra-block`, `locator-no-locals`,
  `locator-value-not-literal`, `locator-misplaced`, `locator-missing`,
  `locator-parse-error`.
- `placeholders`: `account-id-not-placeholder`, `guid-not-placeholder`,
  `hostname-not-placeholder`, `email-not-placeholder`.
- `ascii`: `em-dash`, `en-dash`, `utf8-bom`, `non-ascii`, `invalid-utf8`.
- `no-secrets`: `aws-access-key-id`, `private-key-block`, `jwt`,
  `okta-ssws-token`, `okta-api-token`, `github-token`, `azure-client-secret`,
  `azure-storage-key`, `azure-shared-access-key`, `azure-sas-signature`,
  `slack-webhook`, `literal-secret-assignment`.
- `readme-tables`: `module-not-in-readme`, `stack-not-in-readme`,
  `layout-path-missing`, `layout-block-missing`, `readme-missing`.
- `runbook-params`: `switch-parameter`, `array-parameter`, `write-host`.
- `adr-index`: `status-missing`, `date-missing`, `title-number-mismatch`,
  `number-gap`, `number-duplicate`, `first-not-0001`, `adr-dir-missing`.

### The id allowlist

`microsoft_builtin_ids.txt` lists the GUIDs that may appear without being
placeholders: Azure built-in role definition ids, Entra directory role
template ids, first-party application ids, and Entra application template
ids. Every line is the id followed
by its published name, so a reviewer can check it against the Microsoft
page for built-in roles or role templates before merging an addition. An id
that is not there and not a repeated digit is a finding; the fix is to add
the line with its name, never to widen the pattern.

### What the tools read

`repo_lint.py` reads the files git knows about when `--root` is a repository
(`git ls-files`, tracked plus untracked files git does not ignore, so a new
file is checked before it is added) and walks the tree otherwise, which is
how the fixture trees are read. `--files walk` forces the walk. The linter's
own fixture tree (`tools/repo_lint/tests/fixtures/`) is excluded by default
because it holds deliberately bad examples; `--exclude PREFIX` replaces
that list.

## cells.py: cells from the tree, not from hand-maintained jobs

ADR 0017 states the cost of the current release trains plainly: "The
release trains carry one hardcoded plan and apply job per cell, so a new
cell also needs its two jobs added there." Each PR workflow also carries its
own shell that finds cells with `find tenants/<cloud> -name terragrunt.hcl`
and decides which ones a change affects. Those are three copies of the same
knowledge, and the wave order in each train's header comment is a fourth.
`cells.py` computes all of it from the tree so a workflow can read it
instead of restating it. A cell is found by its `terragrunt.hcl`, never by
depth, so a cell inside another cell's directory (an application's own
catalog cell, `apps/<app>/catalog`, beside its app cell) is discovered on
its own, and the `.hcl` fragments beside a `terragrunt.hcl` are part of
that cell, not cells of their own. `.github/workflows/aws-release.yml` and
`okta-release.yml` read it, each in a `cells` job whose outputs drive one plan
and one apply job per wave (`--family aws` and `--family okta`), and
`okta-pr-validation.yml` pipes the changed paths into `--changed-from -`
and plans only the cells it selects; `aws-pr-validation.yml` still selects
with find and grep. The Okta train
moved onto it when the `okta-applications` cells arrived (ADR 0020): those
cells carry a `dependencies` block on their org's `okta-config` cell, so
the waves are dev's config cell, then dev's applications cell, then the
same two for prod behind the gate. `azure-release.yml` is the follow-up
ADR 0018 names.

### Which cells a change touches

Given the changed paths of a pull request or a push (`--changed`,
`--changed-from FILE`, `--changed-from -` for standard input, or
`--diff BASE HEAD`), every cell is selected for a reason or not at all:

| Reason | Selected when | Why that is a plan change |
|--------|---------------|---------------------------|
| `cell-files` | a file inside the cell's own directory changed, and no deeper cell's directory holds it: a changed path belongs to the deepest cell whose directory contains it, so a fragment of `apps/orders-api/catalog` selects that catalog cell and not the app cell it sits inside, and the app cell's own `terragrunt.hcl` selects the app cell alone | the cell's values, its fragments included, are the plan's inputs |
| `stack` | a file inside the stack the cell calls changed | the stack is the cell's composition |
| `module` | a file inside a module the stack composes changed, read from `source = "../..."` lines in the stack's `.tf` files and followed transitively | a module holds the resources every cell of every stack that composes it will plan |
| `root` | `tenants/<family>/root.hcl` changed | the root generates state and provider configuration for every cell of the family |
| `locator` | a `partition.hcl`, `account.hcl`, or `subscription.hcl` above the cell changed | a locator addresses every cell beneath it (ADR 0017); the PR workflows already re-plan on this |
| `automation-assets` | `automation/lib/`, `automation/runbooks/`, or `policies/` changed and the cell calls `azure-automation` | that stack publishes the runbooks (with the library inlined, ADR 0013) and the desired-state files as Automation variables (ADR 0012, ADR 0015), so their text is in its plan |
| `all` | `--all`, or no selection option at all | everything |

`--explain` prints one line per cell saying which reason fired and on which
path, or `not selected`. Changes to the workflows themselves are not a
reason: a workflow that wants to re-plan everything when it is edited says
so in its own `if`.

### The order of the waves

The selected cells are placed in waves so that every cell's prerequisites
sit in an earlier wave. The edges are the rules the trains already state:

1. A Terragrunt `dependencies` block is honoured.
2. Inside one account or subscription: baseline, then catalog
   (`*-workloads`), then app stacks (`stacks/apps/...`). Both release trains
   state this once in their header; the AWS train's words are "aws-account-baseline,
   then aws-account-workloads, then the app stacks".
3. Inside one tenant: the definitions cell (`azure-rbac-roles`) before the
   cells that resolve custom roles by name at plan time, `azure-pim-governance`
   and `azure-automation` (ADR 0005; README, Verification status).
4. Inside one tenant or partition: tenant-wide cells before the cells scoped
   to one account or subscription, because both trains apply the scoped cells
   after the tenant-wide ones.
5. The first tenant of a family before the gated one: `dev` then `prod`,
   `corp` then `subsidiary`, `commercial` then `govcloud` (README, Promotion
   is gated). The command line refuses a cell under a tenant that table
   does not name, or under a family it does not know, with exit 2 and the
   cell in the message: the release trains name their GitHub environments
   `<tenant>-plan`, `<tenant>`, and `<tenant>-apply` from the tenant, and an
   environment nobody created is created on first use with no reviewers, so
   a new tenant goes into `PROMOTION_ORDER` and into the repository's
   environments before it gets a cell. (The library function `order_waves`
   still places such a cell after the known tenants, so a caller that
   extends the table gets the same waves.) It also refuses, before reading
   the file, a cell whose path holds a directory name outside letters,
   digits, dot, hyphen, and underscore, because the trains use that path as
   a job name and a shell word. `repo_lint` reports both as `cell-shape`
   findings, `tenant-unknown` and `path-characters`, so a pull request sees
   them before a train does.

Families are independent trains, so their waves are numbered from zero
separately and merged by index. A cell's `kind` is read from the stack it
calls: `app` under `stacks/apps/`, `definitions` for `azure-rbac-roles`,
`baseline` for `*-baseline`, `catalog` for `*-workloads`, `platform` for the
rest. A cycle between a `dependencies` block and these rules is an input
error (exit 2) with the cells named.

### The matrix

`--github-matrix` prints one JSON line:

```
{
  "wave_count": 6, "cell_count": 22,
  "wave_sizes": [7, 5, 3, 2, 2, 3],
  "waves": [[cell, cell, ...], [...], ...],
  "families": {"azure": [[...], [...]], "aws": [[...]], "okta": [[...]]},
  "family_wave_sizes": {"azure": [5, 2, 1, 1, 1, 3], ...},
  "cells": [every selected cell, in wave order]
}
```

Each cell entry carries `path` (from the repository root), `family_path`
(from `tenants/<family>`, which is what the existing workflows call
`matrix.cell.path`), `id` (the same slug the existing concurrency groups use
after `azure-cell-`), `family`, `tenant`, `scope` and `scope_name`, `stack`,
`stack_name`, `kind`, `gated` (true for the second tenant of a family, so the
job can pick the gated environment), `wave`, `depends_on`, and `reasons`.
`--pad-waves N` emits at least N waves so a workflow with a fixed number of
wave jobs can index them; an empty wave has size 0 and its job skips itself.

A release train per family then looks like this, with one job per wave
instead of two jobs per cell:

```yaml
jobs:
  cells:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.cells.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: cells
        run: |
          matrix=$(python3 tools/repo_lint/cells.py --family azure \
            --diff "${{ github.event.before }}" "${{ github.sha }}" \
            --github-matrix --pad-waves 6)
          echo "matrix=$matrix" >> "$GITHUB_OUTPUT"

  wave-0:
    needs: [cells]
    if: fromJson(needs.cells.outputs.matrix).family_wave_sizes.azure[0] > 0
    strategy:
      fail-fast: false
      matrix:
        cell: ${{ fromJson(needs.cells.outputs.matrix).families.azure[0] }}
    environment: ${{ matrix.cell.tenant }}
    concurrency:
      group: azure-cell-${{ matrix.cell.id }}
      cancel-in-progress: false
    env:
      # Read as $CELL_ID and $CELL_PATH inside run blocks, never as a matrix
      # expression there, so a directory name is data to the shell.
      CELL_ID: ${{ matrix.cell.id }}
      CELL_PATH: ${{ matrix.cell.family_path }}
    steps:
      # plan and apply tenants/azure/${{ matrix.cell.family_path }},
      # exactly as the per-cell jobs do today

  wave-1:
    needs: [cells, wave-0]
    # No always() here: the implicit success() skips this wave when wave 0
    # failed or was skipped, which is the rule the AWS train states as "a
    # red cell stops the train at its wave". Empty waves therefore have to
    # sit at the tail, which is what the AWS train's cells job arranges when
    # it drops empty waves and pads the list back to its job count.
    if: fromJson(needs.cells.outputs.matrix).family_wave_sizes.azure[1] > 0
    # ... the same job with index 1
```

What this does not replace: the merge-time plan of the gated tenant, its
environment protection rules, and the authentication methods job (which is
not a cell, ADR 0012). Those stay as they are; the waves say when each cell
runs, and `gated` says which environment it runs under.

## Running locally

From the repository root, with Python 3.11 or later (`python3` on the
runners; on a Windows workstation where Python is not on PATH, the full
path to `python.exe` works the same):

```bash
python3 tools/repo_lint/repo_lint.py                       # every check, text output
python3 tools/repo_lint/repo_lint.py --check placeholders --check ascii
python3 tools/repo_lint/repo_lint.py --skip readme-tables --json
python3 tools/repo_lint/repo_lint.py --list-checks

python3 tools/repo_lint/cells.py                           # every cell, in waves
python3 tools/repo_lint/cells.py --changed tenants/aws/commercial/partition.hcl --explain
python3 tools/repo_lint/cells.py --diff origin/main HEAD --github-matrix
git diff --name-only origin/main | python3 tools/repo_lint/cells.py --changed-from - --family azure

python3 -m pytest tools/repo_lint/tests -q
```

Both tools also run as modules (`python3 -m tools.repo_lint.repo_lint`)
and take `--help`.

Exit codes for `repo_lint.py`: 0 when every selected check passed, 1 when
there is at least one finding, 2 for a usage or input error (an unknown
check name, a root that is not a directory, a malformed allowlist). For
`cells.py`: 0 on success, 2 for a usage or input error (no `tenants/`
directory, a cell that cannot be read, named in the message, a directory
name a workflow could not use, a tenant the promotion order does not name,
a dependency cycle).

The text output is one line per finding, `check  path:line  [code] message`,
followed by a summary line. `--json` gives the same as an object with
`checks`, `files_scanned`, `ok`, `findings`, and a `summary` with counts per
check.

## Tests

`tests/fixtures/good/` is a miniature copy of this repository's layout that
passes every check and exercises every selection reason and every wave
rule: three families, both tenants of each, an account with a baseline, a
catalog, an app cell, and the app's own catalog cell nested beside it and
written as fragments, a subscription with the same, a stack that
composes a module that composes another module, and a runbook with a nested
function that takes an array. `tests/fixtures/bad/` fails every check that
can be failed with files that are themselves ASCII and free of
secret-looking strings: one cell per `cell-shape` code, one cell per
`fragment-shape` code (with the fragment that breaks the rule beside it), a locator per
`locators` code, one file of non-placeholder values, an unlisted module and
stack, a runbook with a switch, an array, and `Write-Host`, and a decision
record index with a hole. The fixture Terraform declares no resources and
carries `required_version` and documented, typed variables, so the
repository's own `terraform fmt`, `tflint --recursive`, and checkov runs,
which walk the whole tree, find nothing to say there.

The `ascii` and `no-secrets` failures, the one cell that cannot be
parsed, and the one fragment that cannot, are written into a copy of the good tree at test time, from
`chr()` calls and concatenated fragments, so the repository never carries a
non-ASCII byte, a credential-shaped string, or an `.hcl` file that
`terragrunt hclfmt --check` would refuse. Assertions match on codes, paths,
and line numbers, never on the offending values, so the test files pass the
checks too.

When `python-hcl2` is installed, one test cross-checks the tokenizer's view
of every fixture cell against it; when it is not, that test is skipped and
nothing else changes. The tokenizer is the parser on purpose: hcl2's output
shape has changed between major versions (values keeping their quotes,
`__is_block__` and `__comments__` keys), and the four things these tools
need from a file (top-level block names, `terraform.source`,
`dependencies.paths`, the string locals of a locator) are read deterministically
by a scanner that understands comments, strings with `${...}` templates, and
heredocs.

## Limits, stated

- Hostnames are matched in lower case, as they are written in configuration.
  A mixed-case value such as a .NET type name is not a hostname to this tool.
  A Terraform reference whose attribute happens to be a top-level domain
  (`var.app_name`) is skipped by its root.
- Any 12-digit run bounded by non-alphanumerics is treated as an account id.
  GUIDs are blanked first so a role id's last group is not counted twice.
- The HCL reader is not an evaluator. A `source` built from a template is
  refused as `source-not-static` rather than resolved, which is the rule
  anyway (a cell's source is a literal path).
- `cells.py` reads `dependencies` blocks; a `dependency` block (singular,
  with outputs) is not part of the cell shape this repository allows and is
  refused by `cell-shape`.
- The `no-secrets` assignment heuristic reads a bare value with no digit
  and the shape of a word or an identifier as code (`Environment`,
  `check_no_secrets`), a Verb-Noun as a cmdlet, and a quoted all-caps name
  with underscores as the name of an environment variable. A quoted
  passphrase is still a finding; a bare one with no digit in it is not.
  `Authorization: Bearer <opaque>` is not matched on its own, because an
  opaque bearer value has no shape and the tokens this repository's tests
  hand their mocks are exactly that; a real bearer token here is a JWT, and
  that shape is matched wherever it sits.
- A JWT is matched only when its payload segment starts with `eyJ`, as
  every JSON claims set does. A JWE (five segments, an encrypted key in the
  second) is not a JWT and is not matched.
- Neither tool runs Terraform or Terragrunt. What `terraform validate` and a
  plan check is still theirs; these tools check what a reviewer would
  otherwise have to remember.
