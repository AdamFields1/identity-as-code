"""Every check gets a passing fixture (the good tree) and a failing one.

Assertions are on finding codes and paths, never on the offending values, so
this file itself stays clean under the placeholders check.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from repo_lint import cells, repo_lint

TOOL = Path(repo_lint.__file__).resolve()


def codes(report: repo_lint.Report, path_suffix: str | None = None) -> list[tuple[str, str]]:
    return sorted(
        (f.path, f.code)
        for f in report.findings
        if path_suffix is None or f.path.endswith(path_suffix)
    )


def run(root: Path, *names: str) -> repo_lint.Report:
    return repo_lint.run_checks(root, list(names) or None, files_mode="walk")


# ---------------------------------------------------------------------------
# The good tree passes everything.
# ---------------------------------------------------------------------------


def test_good_tree_passes_every_check(good_root: Path) -> None:
    report = run(good_root)
    assert report.ok, [f.format() for f in report.findings]
    assert report.checks == list(repo_lint.CHECKS)
    assert report.files_scanned > 40


@pytest.mark.parametrize("name", list(repo_lint.CHECKS))
def test_every_check_has_a_rationale_line(name: str) -> None:
    line = repo_lint.check_rationale(name)
    assert line.startswith(name + ":")
    assert "(" in line and ")" in line, "the rationale names the README sentence or ADR it comes from"


# ---------------------------------------------------------------------------
# cell-shape
# ---------------------------------------------------------------------------


def test_cell_shape_refuses_every_forbidden_block(bad_root: Path) -> None:
    report = run(bad_root, "cell-shape")
    forbidden = [
        f.message.split(":")[0].split(" ")[0]
        for f in report.findings
        if f.path.endswith("has-resources/terragrunt.hcl") and f.code == "forbidden-block"
    ]
    assert sorted(forbidden) == sorted(
        ["resource", "data", "module", "locals", "variable", "output", "provider", "generate"]
    )


def test_cell_shape_source_rules(bad_root: Path) -> None:
    report = run(bad_root, "cell-shape")
    assert ("tenants/azure/corp/bad-source/terragrunt.hcl", "source-not-under-stacks") in codes(report)
    assert ("tenants/azure/corp/no-such-stack/terragrunt.hcl", "source-missing") in codes(report)
    assert ("tenants/azure/corp/dynamic-source/terragrunt.hcl", "source-not-static") in codes(report)


def test_cell_shape_dependency_must_be_a_cell(bad_root: Path, good_root: Path) -> None:
    # A dependencies path that resolves to a directory with no terragrunt.hcl
    # is what a cell's dependents look like after the cell moved one level
    # down; Terragrunt would fail on it at run time and cells.py drops it.
    found = codes(run(bad_root, "cell-shape"))
    assert ("tenants/azure/corp/dangling-dependency/terragrunt.hcl", "dependency-missing") in found
    assert [c for c in found if c[0] == "tenants/azure/corp/dangling-dependency/terragrunt.hcl"] == [
        ("tenants/azure/corp/dangling-dependency/terragrunt.hcl", "dependency-missing")
    ]
    assert not [c for c in codes(run(good_root, "cell-shape")) if c[1].startswith("dependency")]


def test_cell_shape_missing_and_duplicate_blocks(bad_root: Path) -> None:
    report = run(bad_root, "cell-shape")
    found = codes(report, "missing-things/terragrunt.hcl")
    assert ("tenants/azure/corp/missing-things/terragrunt.hcl", "missing-include") in found
    assert ("tenants/azure/corp/missing-things/terragrunt.hcl", "missing-source") in found
    assert ("tenants/azure/corp/missing-things/terragrunt.hcl", "duplicate-block") in found
    assert ("tenants/azure/corp/inputs-block/terragrunt.hcl", "inputs-not-attribute") in codes(report)


def test_cell_shape_reports_a_cell_it_cannot_read(good_copy: Path) -> None:
    # Written at test time: a shipped unparsable .hcl would fail the repository's
    # own `terragrunt hclfmt --check`, which formats every .hcl file in the tree.
    broken = good_copy / "tenants" / "azure" / "corp" / "broken" / "terragrunt.hcl"
    broken.parent.mkdir()
    broken.write_text('include "root" {\n  path = find_in_parent_folders("root.hcl")\n', encoding="ascii")
    assert codes(run(good_copy, "cell-shape")) == [("tenants/azure/corp/broken/terragrunt.hcl", "parse-error")]


def test_cell_shape_accepts_good_cells_with_dependencies(good_root: Path) -> None:
    report = run(good_root, "cell-shape")
    assert report.ok


def test_cell_shape_path_characters_and_tenant_rules(bad_root: Path, good_root: Path) -> None:
    # The trains use a cell's path as a job name and a shell word, and name
    # their environments from its tenant (docs/adr/0018); both are refused
    # here and by cells.py.
    found = codes(run(bad_root, "cell-shape"))
    assert ("tenants/azure/corp/odd cell/terragrunt.hcl", "path-characters") in found
    assert ("tenants/aws/nolocator/aws-identity-center/terragrunt.hcl", "tenant-unknown") in found
    odd = [f for f in run(bad_root, "cell-shape").findings if f.code == "path-characters"]
    assert len(odd) == 1 and "'odd cell'" in odd[0].message
    assert [f.code for f in repo_lint._cell_path_findings("tenants/gcp/dev/terragrunt.hcl")] == ["tenant-unknown"]
    assert repo_lint._cell_path_findings("tenants/azure/corp/subscriptions/sub-example-prod/apps/data-pipeline/terragrunt.hcl") == []
    assert not [c for c in codes(run(good_root, "cell-shape")) if c[1] in ("path-characters", "tenant-unknown")]


# ---------------------------------------------------------------------------
# locators
# ---------------------------------------------------------------------------


def test_locators_partition_rules(bad_root: Path) -> None:
    found = codes(run(bad_root, "locators"))
    assert ("tenants/aws/commercial/partition.hcl", "partition-invalid") in found
    assert ("tenants/aws/commercial/partition.hcl", "partition-region-missing") in found
    assert ("tenants/aws/govcloud/partition.hcl", "partition-region-mismatch") in found


def test_locators_account_rules(bad_root: Path) -> None:
    found = codes(run(bad_root, "locators"))
    assert ("tenants/aws/commercial/accounts/acct-a/account.hcl", "account-id-invalid") in found
    assert ("tenants/aws/commercial/accounts/acct-a/account.hcl", "account-name-mismatch") in found
    assert ("tenants/aws/commercial/accounts/acct-e/account.hcl", "locator-value-not-literal") in found


def test_locators_subscription_rules(bad_root: Path) -> None:
    found = codes(run(bad_root, "locators"))
    sub = "tenants/azure/corp/subscriptions/sub-a/subscription.hcl"
    assert (sub, "subscription-id-invalid") in found
    assert (sub, "subscription-name-mismatch") in found
    assert (sub, "locator-extra-block") in found


def test_locators_placement_and_presence(bad_root: Path) -> None:
    found = codes(run(bad_root, "locators"))
    assert ("tenants/azure/corp/subscription.hcl", "locator-misplaced") in found
    assert ("tenants/azure/corp/subscriptions/sub-c/subscription.hcl", "locator-missing") in found
    assert ("tenants/aws/commercial/accounts/acct-d/account.hcl", "locator-missing") in found
    assert ("tenants/aws/nolocator/partition.hcl", "locator-missing") in found


def test_locators_pass_on_good_tree(good_root: Path) -> None:
    assert run(good_root, "locators").ok


# ---------------------------------------------------------------------------
# placeholders
# ---------------------------------------------------------------------------


def test_placeholders_flags_each_kind_once(bad_root: Path) -> None:
    report = run(bad_root, "placeholders")
    found = [(f.code, f.line) for f in report.findings if f.path == "policies/placeholders/bad-values.hcl"]
    assert sorted(found) == sorted(
        [
            ("account-id-not-placeholder", 4),
            ("guid-not-placeholder", 5),
            ("hostname-not-placeholder", 6),
            ("email-not-placeholder", 7),
        ]
    )


def test_placeholders_allow_repeated_digits_zeros_builtin_ids_and_vendor_hosts(good_root: Path) -> None:
    assert run(good_root, "placeholders").ok


def test_builtin_id_allowlist_is_well_formed() -> None:
    ids = repo_lint.load_builtin_ids()
    assert len(ids) >= 6
    assert all(desc for desc in ids.values()), "every id carries its published name"
    assert "8e3af657-a8ff-443c-a75c-2fe8c4bcb635" in ids


def test_builtin_id_allowlist_rejects_malformed_lines(tmp_path: Path) -> None:
    bad = tmp_path / "ids.txt"
    bad.write_text("# comment\nnot-a-guid  Something\n", encoding="ascii")
    with pytest.raises(ValueError):
        repo_lint.load_builtin_ids(bad)


# ---------------------------------------------------------------------------
# ascii (the failing files are written at test time; see conftest)
# ---------------------------------------------------------------------------


def test_ascii_reports_dashes_bom_and_other_characters(good_copy: Path) -> None:
    # Built with chr() so this source file stays ASCII under its own check.
    em_dash, en_dash, e_acute = chr(0x2014), chr(0x2013), chr(0xE9)
    note = good_copy / "docs" / "note.md"
    note.write_bytes(f"plain\nem {em_dash} dash\nen {en_dash} dash\ncaf{e_acute}\n".encode("utf-8"))
    (good_copy / "docs" / "bom.md").write_bytes(b"\xef\xbb\xbfhello\n")
    (good_copy / "docs" / "latin1.md").write_bytes(b"caf\xe9\n")
    report = run(good_copy, "ascii")
    found = {(f.path, f.code, f.line) for f in report.findings}
    assert ("docs/note.md", "em-dash", 2) in found
    assert ("docs/note.md", "en-dash", 3) in found
    assert ("docs/note.md", "non-ascii", 4) in found
    assert ("docs/bom.md", "utf8-bom", 1) in found
    assert ("docs/latin1.md", "invalid-utf8", 1) in found
    em = next(f for f in report.findings if f.code == "em-dash")
    assert "U+2014" in em.message and "column 4" in em.message
    other = next(f for f in report.findings if f.code == "non-ascii")
    assert "U+00E9" in other.message


def test_ascii_passes_and_skips_binary(good_copy: Path) -> None:
    (good_copy / "docs" / "blob.bin").write_bytes(b"\x00\x01\xff\xfe")
    assert run(good_copy, "ascii").ok


# ---------------------------------------------------------------------------
# no-secrets (the failing files are written at test time; see conftest)
# ---------------------------------------------------------------------------


def _leaks() -> list[tuple[str, list[str]]]:
    """Lines for a leak file, each with the codes the check must report for it.

    Every credential-shaped value is split across string fragments, so this
    file, which the shaped detectors read too, holds none of them whole; and
    no value is one repeated character, which reads as a placeholder.
    """
    v = "abcdefghij"
    d = "abcde12345"  # a bare literal with digits, as a credential written bare has
    return [
        # one failing line per shaped detector
        ("$key = '" + "AKIA" + "Q" * 16 + "'", ["aws-access-key-id"]),
        ("-----BEGIN " + "RSA PRIVATE KEY-----", ["private-key-block"]),
        ("$jwt = '" + "eyJ" + v * 2 + "." + "eyJ" + v * 2 + "." + v * 2 + "'", ["jwt"]),
        ("$header = 'SSWS " + "0123456789" * 3 + "'", ["okta-ssws-token"]),
        ("Set-Content token.txt " + "00" + v * 4, ["okta-api-token"]),
        ("gh auth login --with-token <<< " + "ghp_" + v * 3 + "klmnop", ["github-token"]),
        ("echo " + "github_pat_" + v * 8 + "kl", ["github-token"]),
        ("az login --service-principal -p " + "abc" + "8Q~" + v * 3 + "klmn", ["azure-client-secret"]),
        ("$cs = 'DefaultEndpointsProtocol=https;AccountName=acct;" + "AccountKey=" + (v * 9)[:86] + "=='", ["azure-storage-key"]),
        ("$sb = 'Endpoint=sb://ns.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;" + "SharedAccessKey=" + v * 4 + "='", ["azure-shared-access-key"]),
        ("$url = 'https://acct.blob.core.windows.net/c/b?sv=2024&" + "sig=" + v * 4 + "%3D'", ["azure-sas-signature"]),
        ("$hook = 'https://" + "hooks.slack" + ".com/services/T0AB1CD2E/B0FG3HI4J/" + v + "'", ["slack-webhook"]),
        # the assignment heuristic: quoted values, bare values, and the wider name list
        ("client_secret = 'abcdefghij'", ["literal-secret-assignment"]),
        ('"password": "hunter2hunter2",', ["literal-secret-assignment"]),
        ('api_token = "' + v * 2 + '"', ["literal-secret-assignment"]),
        ("export OKTA_API_TOKEN=" + d * 2 + "klmn", ["literal-secret-assignment"]),
        ("aws_secret_access_key = " + "wJalrXUtnFEMI/K7MDENG/bPxRfiCY" + v, ["literal-secret-assignment"]),
        ("export ARM_CLIENT_SECRET=" + "abc" + "8Q~" + v * 3 + "klmn", ["azure-client-secret", "literal-secret-assignment"]),
        ("$env:GH_TOKEN = 'plainvaluehere'", ["literal-secret-assignment"]),
        ('connection_string = "Server=db;User=app;Password=' + v + '"', ["literal-secret-assignment"]),
        ("sas_token = '?sv=2024&ss=b&srt=sco&sp=rl'", ["literal-secret-assignment"]),
        # passing lines: placeholders, short values, references, variables, URLs, paths, and near misses
        ("password = 'CHANGEME-not-real'", []),
        ("api_key = 'short'", []),
        ('secret_token = "${var.scim_token}"', []),
        ("$apiKey = '<paste token, do not commit>'", []),
        ("client_secret = var.client_secret", []),
        ("access_token = local.session.token", []),
        ("AccessToken = $AccessToken", []),
        ('token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token"', []),
        ('private_key_path = "/home/runner/.ssh/id_ed25519"', []),
        ("credential_source = Environment", []),
        ("sasl_mechanism = 'SCRAM-SHA-512'", []),
        ("$fake = '" + "eyJ" + v * 2 + "." + "armpayload" + v + "." + v * 2 + "'", []),
        ("SharedAccessKeyName=RootManageSharedAccessKey", []),
        ("sig=[redacted]", []),
        ("gh_token = '" + "ghp_" + "x" * 36 + "'", []),
        # code shapes the bare rule reads as code, and a quoted name of a variable
        ("$token = Get-RunbookAccessToken -Resource Arm", []),
        ("$password = Select-OktaPolicy -Policies $policies -Label 'password'", []),
        ('"no-secrets": check_no_secrets,', []),
        ("[string]$TokenEnvVar = 'OKTA_API_TOKEN',", []),
        ("# credential_source = Environment. The state backend keeps the session.", []),
        ("$body = '{\"keyCredentials\":' + (ConvertTo-Json -InputObject @($remaining) -Depth 5) + '}'", []),
        ("$token = \"Bearer $accessToken\"", []),
        ("export DB_PASSWORD=correcthorsebatterystaple", []),
    ]


def _leak_text() -> str:
    return "\n".join(line for line, _ in _leaks()) + "\n"


def test_no_secrets_flags_each_pattern(good_copy: Path) -> None:
    leak = good_copy / "scripts" / "leak.ps1"
    leak.parent.mkdir()
    leak.write_text(_leak_text(), encoding="ascii")
    report = run(good_copy, "no-secrets")
    found = sorted((f.line, f.code) for f in report.findings if f.path == "scripts/leak.ps1")
    expected = sorted((lineno, code) for lineno, (_, expected_codes) in enumerate(_leaks(), start=1) for code in expected_codes)
    assert found == expected
    for f in report.findings:
        assert "hunter2" not in f.message and "AKIA" not in f.message and "8Q~" not in f.message, "findings never quote the match"
    shaped = {code for code, _, _ in repo_lint._SECRET_PATTERNS}
    assert {code for _, expected_codes in _leaks() for code in expected_codes} == shaped | {"literal-secret-assignment"}, "every detector has a failing line"


def test_no_secrets_detectors_read_test_files_and_the_heuristic_does_not(good_copy: Path) -> None:
    # A test assigns stand-in tokens by construction, so the assignment
    # heuristic skips test files; a credential with a real shape pasted into
    # one to reach a live tenant is still a finding.
    paths = ("automation/tests/Leak.Tests.ps1", "tools/thing/test_leak.py", "x/__tests__/leak.json")
    for rel in paths:
        target = good_copy / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(_leak_text(), encoding="ascii")
    report = run(good_copy, "no-secrets")
    by_path: dict[str, set[str]] = {}
    for f in report.findings:
        by_path.setdefault(f.path, set()).add(f.code)
    shaped = {code for code, _, _ in repo_lint._SECRET_PATTERNS}
    for rel in paths:
        assert by_path[rel] == shaped, rel


def test_no_secrets_passes_on_good_tree(good_root: Path) -> None:
    assert run(good_root, "no-secrets").ok


# ---------------------------------------------------------------------------
# readme-tables
# ---------------------------------------------------------------------------


def test_readme_tables_flags_unnamed_dirs_and_missing_layout_paths(bad_root: Path) -> None:
    found = codes(run(bad_root, "readme-tables"))
    assert ("modules/azure/unlisted-module", "module-not-in-readme") in found
    assert ("stacks/unlisted-stack", "stack-not-in-readme") in found
    assert ("stacks/apps/azure/unlisted-app", "stack-not-in-readme") in found
    layout = [f for f in run(bad_root, "readme-tables").findings if f.code == "layout-path-missing"]
    assert sorted(f.message.split()[2].rstrip(",") for f in layout) == ["docs/nope.md", "stacks/missing-stack"]
    assert all(f.line for f in layout), "layout findings point at the README line"


def test_readme_tables_missing_readme_and_layout(good_copy: Path) -> None:
    readme = good_copy / "README.md"
    readme.write_text("# no layout here\n\nmodules/okta/network-zone and friends\n", encoding="ascii")
    found = codes(run(good_copy, "readme-tables"))
    assert ("README.md", "layout-block-missing") in found
    readme.unlink()
    assert codes(run(good_copy, "readme-tables")) == [("README.md", "readme-missing")]


def test_layout_paths_parse_tree_and_skip_description_continuations() -> None:
    readme = "\n".join(
        [
            "# x",
            "",
            "## Layout",
            "",
            "```",
            "identity-as-code/",
            "  modules/",
            "    okta/                       network-zone, session-policy,",
            "                                mfa-policy",
            "  stacks/                       units of deployment",
            "    apps/",
            "      aws/payments-api/",
            "  tenants/",
            "    okta/",
            "      root.hcl                  state",
            "      dev/terragrunt.hcl",
            "```",
        ]
    )
    paths = [p for p, _ in repo_lint.layout_paths(readme)]
    assert paths == [
        "modules",
        "modules/okta",
        "stacks",
        "stacks/apps",
        "stacks/apps/aws/payments-api",
        "tenants",
        "tenants/okta",
        "tenants/okta/root.hcl",
        "tenants/okta/dev/terragrunt.hcl",
    ]


def test_readme_tables_pass_on_good_tree(good_root: Path) -> None:
    assert run(good_root, "readme-tables").ok


# ---------------------------------------------------------------------------
# runbook-params
# ---------------------------------------------------------------------------


def test_runbook_params_flags_switch_array_and_write_host(bad_root: Path) -> None:
    report = run(bad_root, "runbook-params")
    found = sorted((f.code, f.line) for f in report.findings if f.path == "automation/runbooks/Bad-Runbook.ps1")
    assert found == [("array-parameter", 8), ("switch-parameter", 6), ("write-host", 13), ("write-host", 17)]
    switch = next(f for f in report.findings if f.code == "switch-parameter")
    assert "$Force" in switch.message
    array = next(f for f in report.findings if f.code == "array-parameter")
    assert "$Names" in array.message and "[string[]]" in array.message


def test_runbook_params_ignore_nested_functions_strings_and_comments(good_root: Path) -> None:
    assert run(good_root, "runbook-params").ok


def test_blank_powershell_keeps_line_numbers_and_hides_strings() -> None:
    text = "a = 'it''s Write-Host'\nb = \"x $('Write-Host') y\"\n<# Write-Host\n#> c\n@'\nWrite-Host\n'@\n# Write-Host\nWrite-Host d\n"
    blanked = repo_lint.blank_powershell(text)
    assert blanked.count("\n") == text.count("\n")
    assert len(blanked) == len(text)
    assert blanked.count("Write-Host") == 1
    assert blanked.splitlines()[-1].startswith("Write-Host d")


# ---------------------------------------------------------------------------
# adr-index
# ---------------------------------------------------------------------------


def test_adr_index_flags_missing_lines_gaps_and_title_mismatch(bad_root: Path) -> None:
    found = codes(run(bad_root, "adr-index"))
    assert ("docs/adr/0001-first.md", "date-missing") in found
    assert ("docs/adr/0003-third.md", "status-missing") in found
    assert ("docs/adr/0003-third.md", "title-number-mismatch") in found
    assert ("docs/adr", "number-gap") in found


def test_adr_index_duplicate_and_first_number(good_copy: Path) -> None:
    adr = good_copy / "docs" / "adr"
    (adr / "0002-second-copy.md").write_text("# ADR 0002: Copy\n\nStatus: accepted\nDate: 2026-09-12\n", encoding="ascii")
    (adr / "0001-stacks-as-deployment-unit.md").unlink()
    found = codes(run(good_copy, "adr-index"))
    assert ("docs/adr", "number-duplicate") in found
    assert ("docs/adr", "first-not-0001") in found


def test_adr_index_passes_on_good_tree(good_root: Path) -> None:
    assert run(good_root, "adr-index").ok


# ---------------------------------------------------------------------------
# Runner, selection, and command line
# ---------------------------------------------------------------------------


def test_select_checks_only_and_skip() -> None:
    assert repo_lint.select_checks(None, None) == list(repo_lint.CHECKS)
    assert repo_lint.select_checks(["ascii", "cell-shape"], None) == ["cell-shape", "ascii"]
    assert "ascii" not in repo_lint.select_checks(None, ["ascii"])
    with pytest.raises(ValueError):
        repo_lint.select_checks(["nope"], None)


def test_default_excludes_hide_the_fixture_tree(tmp_path: Path, bad_root: Path) -> None:
    import shutil

    nested = tmp_path / "tools" / "repo_lint" / "tests" / "fixtures" / "bad"
    shutil.copytree(bad_root, nested)
    (tmp_path / "README.md").write_text("# root\n", encoding="ascii")
    files = repo_lint.tracked_files(tmp_path, "walk")
    assert files == ["README.md"]
    assert len(repo_lint.tracked_files(tmp_path, "walk", excludes=())) > 1


def _cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True)


def test_cli_exit_codes(good_root: Path, bad_root: Path, tmp_path: Path) -> None:
    assert _cli("--root", str(good_root), "--files", "walk").returncode == 0
    bad = _cli("--root", str(bad_root), "--files", "walk", "--json")
    assert bad.returncode == 1
    report = json.loads(bad.stdout)
    assert report["ok"] is False
    assert report["summary"]["findings"] == len(report["findings"]) > 20
    assert set(report["summary"]["by_check"]) == set(repo_lint.CHECKS)
    assert all(report["summary"]["by_check"][c] > 0 for c in ("cell-shape", "locators", "placeholders", "readme-tables", "runbook-params", "adr-index"))
    assert _cli("--root", str(good_root), "--check", "nope").returncode == 2
    assert _cli("--root", str(tmp_path / "missing")).returncode == 2


def test_cli_check_skip_and_list(good_root: Path, bad_root: Path) -> None:
    only = _cli("--root", str(bad_root), "--files", "walk", "--check", "adr-index", "--json")
    assert only.returncode == 1
    assert json.loads(only.stdout)["checks"] == ["adr-index"]
    skipped = _cli("--root", str(bad_root), "--files", "walk", "--skip", "placeholders", "--json")
    assert "placeholders" not in json.loads(skipped.stdout)["checks"]
    listed = _cli("--list-checks")
    assert listed.returncode == 0
    for name in repo_lint.CHECKS:
        assert name in listed.stdout
    assert _cli("--help").returncode == 0


def test_cli_text_output_names_check_path_and_code(bad_root: Path) -> None:
    out = _cli("--root", str(bad_root), "--files", "walk", "--check", "runbook-params").stdout
    assert "runbook-params  automation/runbooks/Bad-Runbook.ps1:6  [switch-parameter]" in out
    assert out.strip().endswith("file(s)")


# ---------------------------------------------------------------------------
# The HCL reader the checks share
# ---------------------------------------------------------------------------


def test_hcl_reader_handles_templates_heredocs_and_comments() -> None:
    text = "\n".join(
        [
            "# { a brace in a comment",
            "include \"root\" {",
            "  path = find_in_parent_folders(\"root.hcl\") // trailing",
            "}",
            "/* block } comment */",
            "terraform {",
            "  source = \"../../stacks/${replace(\"a}b\", \"}\", \"\")}\"",
            "}",
            "generate \"p\" {",
            "  contents = <<-EOF",
            "    { not a block }",
            "  EOF",
            "}",
            "dependencies {",
            "  paths = [\"../a\", \"../b\",]",
            "}",
            "inputs = {",
            "  nested = { k = \"v\" }",
            "}",
        ]
    )
    items = cells.parse_items(cells.tokenize(text))
    assert [(i.name, i.kind) for i in items] == [
        ("include", "block"),
        ("terraform", "block"),
        ("generate", "block"),
        ("dependencies", "block"),
        ("inputs", "attribute"),
    ]
    assert cells.attributes(items[1].tokens)["source"].startswith("../../stacks/${")
    assert cells.attributes(items[3].tokens)["paths"] == ["../a", "../b"]
    assert isinstance(cells.attributes(items[0].tokens)["path"], cells.Raw)


@pytest.mark.parametrize("text", ["include \"root\" {", "x = \"unterminated", "a = <<EOF\nnever closed\n", "{ = 1"])
def test_hcl_reader_raises_on_broken_input(text: str) -> None:
    with pytest.raises(cells.HclSyntaxError):
        cells.parse_items(cells.tokenize(text))


def test_hcl_reader_agrees_with_python_hcl2_when_installed(good_root: Path) -> None:
    hcl2 = pytest.importorskip("hcl2")
    for path in cells.find_cell_files(good_root):
        with path.open(encoding="utf-8") as handle:
            reference = {k for k in hcl2.load(handle) if not k.startswith("__")}
        ours = {it.name for it in cells.read_hcl(path)}
        assert ours == reference, path
