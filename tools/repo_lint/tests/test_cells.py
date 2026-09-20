"""Cell discovery, every selection reason, and the wave order, on the good tree."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from repo_lint import cells

TOOL = Path(cells.__file__).resolve()

CORP = "tenants/azure/corp"
SUB = "tenants/azure/corp/subscriptions/sub-example-prod"
PROD = "tenants/aws/commercial/accounts/example-prod"


@pytest.fixture(scope="module")
def all_cells(good_root: Path) -> list[cells.Cell]:
    return cells.discover_cells(good_root)


def by_path(found: list[cells.Cell]) -> dict[str, cells.Cell]:
    return {c.path: c for c in found}


def selected_paths(root: Path, found: list[cells.Cell], changed: list[str]) -> dict[str, list[str]]:
    result = cells.select_cells(root, found, changed)
    return {path: sorted({r.code for r in reasons}) for path, reasons in result.items()}


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------


def test_discovery_finds_every_cell_and_no_locator(all_cells: list[cells.Cell]) -> None:
    paths = [c.path for c in all_cells]
    assert len(paths) == 17
    assert all(p.startswith("tenants/") for p in paths)
    assert not any(p.endswith(("subscriptions/sub-example-prod", "accounts/example-prod")) for p in paths)
    assert paths == sorted(paths)


def test_discovery_describes_platform_scoped_and_app_cells(all_cells: list[cells.Cell]) -> None:
    c = by_path(all_cells)
    okta = c["tenants/okta/dev"]
    assert (okta.family, okta.tenant, okta.scope, okta.scope_name) == ("okta", "dev", "tenant", None)
    assert (okta.stack, okta.stack_name, okta.kind) == ("stacks/okta-config", "okta-config", "platform")
    assert okta.family_path == "dev" and okta.id == "dev" and okta.gated is False

    roles = c[f"{CORP}/azure-rbac-roles"]
    assert roles.kind == "definitions" and roles.dependencies == []
    pim = c[f"{CORP}/azure-pim-governance"]
    assert pim.dependencies == [f"{CORP}/azure-rbac-roles"]
    assert pim.id == "corp-azure-pim-governance"

    app = c[f"{SUB}/apps/data-pipeline"]
    assert (app.scope, app.scope_name, app.kind) == ("subscription", "sub-example-prod", "app")
    assert app.stack == "stacks/apps/azure/data-pipeline"
    assert app.family_path == "corp/subscriptions/sub-example-prod/apps/data-pipeline"

    workloads = c[f"{PROD}/aws-account-workloads"]
    assert (workloads.scope, workloads.scope_name, workloads.kind) == ("account", "example-prod", "catalog")
    baseline = c[f"{PROD}/aws-account-baseline"]
    assert baseline.kind == "baseline"
    assert c["tenants/aws/govcloud/aws-identity-center"].gated is True
    assert c["tenants/azure/subsidiary/azure-pim-governance"].gated is True


def test_module_dirs_are_transitive_and_ignore_registry_sources(good_root: Path) -> None:
    assert cells.module_dirs(good_root, "stacks/aws-account-workloads") == {"modules/aws/s3-bucket", "modules/aws/kms-key"}
    assert cells.module_dirs(good_root, "stacks/apps/aws/payments-api") == {"modules/aws/kms-key", "modules/aws/s3-bucket"}
    assert cells.module_dirs(good_root, "stacks/okta-config") == {"modules/okta/network-zone"}


def test_classify_stack_by_path_and_name() -> None:
    assert cells.classify_stack("stacks/apps/aws/x", "x") == "app"
    assert cells.classify_stack("stacks/azure-rbac-roles", "azure-rbac-roles") == "definitions"
    assert cells.classify_stack("stacks/aws-account-baseline", "aws-account-baseline") == "baseline"
    assert cells.classify_stack("stacks/azure-subscription-workloads", "azure-subscription-workloads") == "catalog"
    assert cells.classify_stack("stacks/okta-config", "okta-config") == "platform"
    assert cells.classify_stack(None, "unknown") == "platform"


# ---------------------------------------------------------------------------
# Selection: one test per reason
# ---------------------------------------------------------------------------


def test_reason_cell_files(good_root: Path, all_cells: list[cells.Cell]) -> None:
    picked = selected_paths(good_root, all_cells, [f"{CORP}/azure-pim-governance/terragrunt.hcl"])
    assert picked == {f"{CORP}/azure-pim-governance": ["cell-files"]}


def test_reason_stack(good_root: Path, all_cells: list[cells.Cell]) -> None:
    picked = selected_paths(good_root, all_cells, ["stacks/azure-pim-governance/main.tf"])
    assert picked == {
        f"{CORP}/azure-pim-governance": ["stack"],
        "tenants/azure/subsidiary/azure-pim-governance": ["stack"],
    }


def test_reason_module_direct_and_transitive(good_root: Path, all_cells: list[cells.Cell]) -> None:
    direct = selected_paths(good_root, all_cells, ["modules/entra/conditional-access/main.tf"])
    assert direct == {
        f"{CORP}/entra-conditional-access": ["module"],
        "tenants/azure/subsidiary/entra-conditional-access": ["module"],
    }
    transitive = selected_paths(good_root, all_cells, ["modules/aws/kms-key/main.tf"])
    assert transitive == {
        f"{PROD}/aws-account-baseline": ["module"],
        f"{PROD}/aws-account-workloads": ["module"],
        f"{PROD}/apps/payments-api": ["module"],
        "tenants/aws/commercial/accounts/example-dev/aws-account-baseline": ["module"],
    }


def test_reason_root(good_root: Path, all_cells: list[cells.Cell]) -> None:
    picked = selected_paths(good_root, all_cells, ["tenants/aws/root.hcl"])
    assert set(picked) == {c.path for c in all_cells if c.family == "aws"}
    assert all(v == ["root"] for v in picked.values())


def test_reason_locator_account_partition_and_subscription(good_root: Path, all_cells: list[cells.Cell]) -> None:
    account = selected_paths(good_root, all_cells, [f"{PROD}/account.hcl"])
    assert set(account) == {f"{PROD}/aws-account-baseline", f"{PROD}/aws-account-workloads", f"{PROD}/apps/payments-api"}
    assert all(v == ["locator"] for v in account.values())

    partition = selected_paths(good_root, all_cells, ["tenants/aws/commercial/partition.hcl"])
    assert set(partition) == {c.path for c in all_cells if c.family == "aws" and c.tenant == "commercial"}

    subscription = selected_paths(good_root, all_cells, [f"{SUB}/subscription.hcl"])
    assert set(subscription) == {f"{SUB}/azure-subscription-baseline", f"{SUB}/azure-subscription-workloads", f"{SUB}/apps/data-pipeline"}
    assert all(v == ["locator"] for v in subscription.values())


@pytest.mark.parametrize(
    "changed",
    ["automation/lib/Runbook.Common.ps1", "automation/runbooks/Invoke-Example.ps1", "policies/azure/pim-governance/corp-baseline.json"],
)
def test_reason_automation_assets(good_root: Path, all_cells: list[cells.Cell], changed: str) -> None:
    picked = selected_paths(good_root, all_cells, [changed])
    assert picked == {f"{CORP}/azure-automation": ["automation-assets"]}


def test_reason_all_and_nothing(good_root: Path, all_cells: list[cells.Cell]) -> None:
    everything = cells.select_cells(good_root, all_cells, None, select_all=True)
    assert set(everything) == {c.path for c in all_cells}
    assert all(r == [cells.Reason("all", "")] for r in everything.values())
    assert selected_paths(good_root, all_cells, ["README.md", ".github/workflows/x.yml"]) == {}


def test_selection_records_every_reason_and_normalizes_paths(good_root: Path, all_cells: list[cells.Cell]) -> None:
    changed = [f".\\{CORP}\\azure-automation\\terragrunt.hcl", "./stacks/azure-automation/main.tf", "automation/lib/x.ps1"]
    result = cells.select_cells(good_root, all_cells, changed)
    reasons = {(r.code, r.path) for r in result[f"{CORP}/azure-automation"]}
    assert reasons == {
        ("cell-files", f"{CORP}/azure-automation/terragrunt.hcl"),
        ("stack", "stacks/azure-automation/main.tf"),
        ("automation-assets", "automation/lib/x.ps1"),
    }


# ---------------------------------------------------------------------------
# Waves
# ---------------------------------------------------------------------------


def wave_index(waves: list[list[cells.Cell]]) -> dict[str, int]:
    return {c.path: i for i, wave in enumerate(waves) for c in wave}


def test_waves_for_the_whole_tree(all_cells: list[cells.Cell]) -> None:
    w = wave_index(cells.order_waves(all_cells))
    # okta: dev before prod (promotion order)
    assert w["tenants/okta/dev"] == 0 and w["tenants/okta/prod"] == 1
    # azure corp: definitions before their consumers, dependencies honoured
    assert w[f"{CORP}/azure-rbac-roles"] == 0
    assert w[f"{CORP}/entra-conditional-access"] == 0
    assert w[f"{CORP}/azure-pim-governance"] == 1
    assert w[f"{CORP}/azure-automation"] == 1
    # subscription cells after the tenant-wide ones: baseline, catalog, app
    assert w[f"{SUB}/azure-subscription-baseline"] == 2
    assert w[f"{SUB}/azure-subscription-workloads"] == 3
    assert w[f"{SUB}/apps/data-pipeline"] == 4
    # the gated tenant after everything in corp
    assert w["tenants/azure/subsidiary/azure-pim-governance"] == 5
    assert w["tenants/azure/subsidiary/entra-conditional-access"] == 5
    # aws: identity center, then each account's chain in parallel, then govcloud
    assert w["tenants/aws/commercial/aws-identity-center"] == 0
    assert w[f"{PROD}/aws-account-baseline"] == 1
    assert w["tenants/aws/commercial/accounts/example-dev/aws-account-baseline"] == 1
    assert w[f"{PROD}/aws-account-workloads"] == 2
    assert w[f"{PROD}/apps/payments-api"] == 3
    assert w["tenants/aws/govcloud/aws-identity-center"] == 4


def test_waves_of_a_subset_start_at_zero(all_cells: list[cells.Cell]) -> None:
    subset = [c for c in all_cells if c.path in (f"{SUB}/azure-subscription-workloads", f"{SUB}/apps/data-pipeline")]
    waves = cells.order_waves(subset)
    assert [[c.path for c in w] for w in waves] == [[f"{SUB}/azure-subscription-workloads"], [f"{SUB}/apps/data-pipeline"]]


def test_waves_honour_an_explicit_dependency_without_an_implicit_rule() -> None:
    a = cells.Cell("tenants/azure/corp/a", "azure", "corp", "tenant", None, "stacks/a", "a", "platform", [])
    b = cells.Cell("tenants/azure/corp/b", "azure", "corp", "tenant", None, "stacks/b", "b", "platform", [a.path])
    waves = cells.order_waves([b, a])
    assert [[c.path for c in w] for w in waves] == [[a.path], [b.path]]


def test_waves_detect_a_cycle() -> None:
    a = cells.Cell("tenants/azure/corp/a", "azure", "corp", "tenant", None, "stacks/a", "a", "platform", ["tenants/azure/corp/b"])
    b = cells.Cell("tenants/azure/corp/b", "azure", "corp", "tenant", None, "stacks/b", "b", "platform", ["tenants/azure/corp/a"])
    with pytest.raises(cells.CycleError):
        cells.order_waves([a, b])


def test_unknown_tenants_follow_the_known_ones_and_share_a_wave() -> None:
    dev = cells.Cell("tenants/okta/dev", "okta", "dev", "tenant", None, "stacks/okta-config", "okta-config", "platform", [])
    lab = cells.Cell("tenants/okta/lab", "okta", "lab", "tenant", None, "stacks/okta-config", "okta-config", "platform", [])
    qa = cells.Cell("tenants/okta/qa", "okta", "qa", "tenant", None, "stacks/okta-config", "okta-config", "platform", [])
    w = wave_index(cells.order_waves([qa, lab, dev]))
    assert w == {dev.path: 0, lab.path: 1, qa.path: 1}


# ---------------------------------------------------------------------------
# Matrix and command line
# ---------------------------------------------------------------------------


def test_build_matrix_shape(good_root: Path, all_cells: list[cells.Cell]) -> None:
    selected = cells.select_cells(good_root, all_cells, ["stacks/aws-account-baseline/main.tf"])
    matrix = cells.build_matrix(all_cells, selected, pad_waves=4)
    assert matrix["cell_count"] == 2 and matrix["wave_count"] == 4
    assert [len(w) for w in matrix["waves"]] == [2, 0, 0, 0]
    entry = matrix["waves"][0][0]
    assert entry["wave"] == 0 and entry["reasons"] == [{"code": "stack", "path": "stacks/aws-account-baseline/main.tf"}]
    assert set(entry) >= {"path", "family_path", "id", "family", "tenant", "scope", "scope_name", "stack", "stack_name", "kind", "gated", "depends_on"}
    assert list(matrix["families"]) == ["aws"]
    assert matrix["wave_sizes"] == [2, 0, 0, 0]
    assert matrix["family_wave_sizes"] == {"aws": [2, 0, 0, 0]}
    assert matrix["cells"] == matrix["waves"][0]


def _cli(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True, input=stdin)


def test_cli_github_matrix_is_one_json_line(good_root: Path) -> None:
    result = _cli("--root", str(good_root), "--github-matrix")
    assert result.returncode == 0
    assert result.stdout.count("\n") == 1
    matrix = json.loads(result.stdout)
    assert matrix["cell_count"] == 17 and matrix["wave_count"] == 6
    assert set(matrix["families"]) == {"okta", "azure", "aws"}
    assert len(matrix["families"]["okta"]) == 2


def test_cli_changed_family_filter_and_explain(good_root: Path) -> None:
    result = _cli("--root", str(good_root), "--family", "aws", "--changed", "tenants/aws/root.hcl", "--explain")
    assert result.returncode == 0
    assert "6 cell(s) in 5 wave(s)" in result.stdout
    assert "tenants/aws/govcloud/aws-identity-center: selected, root (tenants/aws/root.hcl)" in result.stdout
    assert "tenants/okta/dev" not in result.stdout
    quiet = _cli("--root", str(good_root), "--changed", "README.md", "--explain")
    assert "0 cell(s) in 0 wave(s)" in quiet.stdout
    assert "tenants/okta/dev: not selected" in quiet.stdout


def test_cli_changed_from_stdin_and_pad(good_root: Path) -> None:
    result = _cli("--root", str(good_root), "--changed-from", "-", "--github-matrix", "--pad-waves", "8", stdin="tenants/okta/dev/terragrunt.hcl\n\n./tenants/okta/prod/terragrunt.hcl\n")
    matrix = json.loads(result.stdout)
    assert matrix["wave_count"] == 8 and matrix["cell_count"] == 2
    assert [e["path"] for e in matrix["waves"][0]] == ["tenants/okta/dev"]
    assert [e["path"] for e in matrix["waves"][1]] == ["tenants/okta/prod"]
    assert matrix["waves"][1][0]["gated"] is True


def test_cli_errors_are_exit_2(tmp_path: Path, good_copy: Path) -> None:
    assert _cli("--root", str(tmp_path)).returncode == 2, "no tenants/ directory"
    broken = good_copy / "tenants" / "azure" / "corp" / "broken" / "terragrunt.hcl"
    broken.parent.mkdir()
    broken.write_text('include "root" {\n', encoding="ascii")
    result = _cli("--root", str(good_copy))
    assert result.returncode == 2, result.stderr
    # The message names the cell: a tree of twenty cells with one broken file says which.
    assert "tenants/azure/corp/broken/terragrunt.hcl" in result.stderr and "unclosed" in result.stderr
    assert _cli("--root", str(tmp_path), "--all", "--changed", "x").returncode == 2, "mutually exclusive"


def test_cli_refuses_a_directory_name_a_workflow_could_not_use(good_copy: Path) -> None:
    # The trains put a cell's path and id into job names and shell words; a
    # name outside letters, digits, dot, hyphen, and underscore is refused
    # before the file is read, with the cell and the name in the message.
    source = (good_copy / "tenants" / "azure" / "corp" / "azure-rbac-roles" / "terragrunt.hcl").read_text(encoding="ascii")
    odd = good_copy / "tenants" / "azure" / "corp" / "odd cell" / "terragrunt.hcl"
    odd.parent.mkdir()
    odd.write_text(source, encoding="ascii")
    result = _cli("--root", str(good_copy), "--github-matrix")
    assert result.returncode == 2, result.stderr
    assert "tenants/azure/corp/odd cell/terragrunt.hcl" in result.stderr and "'odd cell'" in result.stderr
    with pytest.raises(cells.CellPathError):
        cells.discover_cells(good_copy)


def test_cli_refuses_a_tenant_the_promotion_order_does_not_name(good_copy: Path) -> None:
    # The trains name their environments from the tenant, and an environment
    # nobody created has no reviewers, so a cell under an unknown tenant is
    # an input error for the command line. The library still orders it (see
    # test_unknown_tenants_follow_the_known_ones_and_share_a_wave), so a
    # caller that extends PROMOTION_ORDER gets the same waves.
    source = (good_copy / "tenants" / "okta" / "dev" / "terragrunt.hcl").read_text(encoding="ascii")
    lab = good_copy / "tenants" / "okta" / "lab" / "terragrunt.hcl"
    lab.parent.mkdir()
    lab.write_text(source, encoding="ascii")
    result = _cli("--root", str(good_copy), "--github-matrix")
    assert result.returncode == 2, result.stderr
    assert "tenants/okta/lab: 'lab' is not a tenant of the okta family (dev, prod)" in result.stderr
    # A train filters to its family first, so only its own tenants can stop it; the lint job runs unfiltered.
    assert _cli("--root", str(good_copy), "--family", "aws", "--github-matrix").returncode == 0
    found = cells.discover_cells(good_copy)
    lines = cells.unknown_tenant_lines(found)
    assert len(lines) == 1 and lines[0].startswith("tenants/okta/lab: 'lab' is not a tenant of the okta family (dev, prod)")
    gcp = cells.Cell("tenants/gcp/dev", "gcp", "dev", "tenant", None, "stacks/x", "x", "platform", [])
    assert cells.unknown_tenant_lines([gcp])[0].startswith("tenants/gcp/dev: 'gcp' is not a family")
    known = [c for c in found if c.path != "tenants/okta/lab"]
    assert cells.unknown_tenant_lines(known) == []


def test_local_module_sources_ignore_registry_and_provider_sources(tmp_path: Path) -> None:
    (tmp_path / "main.tf").write_text(
        'terraform {\n  required_providers {\n    aws = {\n      source  = "hashicorp/aws"\n      version = "~> 6.0"\n    }\n  }\n}\n'
        'module "a" {\n  source = "../../modules/aws/kms-key"\n}\n'
        'module "b" {\n  source = "./local"\n}\n'
        'module "c" {\n  source = "git::https://example.com/x.git"\n}\n',
        encoding="ascii",
    )
    assert cells.local_module_sources(tmp_path) == ["../../modules/aws/kms-key", "./local"]
