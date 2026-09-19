"""Tests for tools/plan_gate.

Every profile has a passing and a failing fixture; every rule the gate
enforces (import counting, replace orderings, neutral reads, drift, noise,
the allowlist match, the errored flag) has a case that passes and one that
fails; the exit codes, the summary table, the JSON document, and the
GITHUB_STEP_SUMMARY writer are exercised through main(). No network, no
Terraform binary: the fixtures are hand-written plan JSON in the shape
Terraform 1.9 emits (format_version 1.2).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

from plan_gate import plan_gate as pg

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
TOOL_DIR = HERE.parent
SCRIPT = TOOL_DIR / "plan_gate.py"

ADOPTION_CLEAN = FIXTURES / "adoption_clean_3_imports.json"
ADOPTION_STRAY = FIXTURES / "adoption_stray_update.json"
CONVERGENCE_CLEAN = FIXTURES / "convergence_clean.json"
CONVERGENCE_DRIFT = FIXTURES / "convergence_drift_only.json"
SCOPED_ALLOWED = FIXTURES / "scoped_replace_allowed.json"
SCOPED_VIOLATION = FIXTURES / "scoped_replace_violation.json"
REPLACE_ACTIONS = FIXTURES / "replace_actions.json"
NOISE_ONLY = FIXTURES / "noise_only.json"
NOT_A_PLAN = FIXTURES / "not_a_plan.json"
MALFORMED = FIXTURES / "malformed.json"

STRAY_ADDRESS = 'module.custom_roles.azurerm_role_definition.this["automation-runner"]'
ZONE_ADDRESS = 'module.network_zones.okta_network_zone.this["corp-egress"]'
RULE_ADDRESS = 'module.session_policy.okta_policy_rule_signon.this["anywhere"]'
RULE_PATTERN = r'module\.session_policy\.okta_policy_rule_signon\.this\[".*"\]'
DRIFT_ADDRESS = (
    'module.pim_eligible_assignment.azurerm_pim_eligible_role_assignment.this'
    '["grp-pim-owners|Owner|sub-example-prod"]'
)


def gate(profile: str, fixture: Path, **kwargs: Any) -> pg.Result:
    """Load a fixture and evaluate it under a profile with the given options."""
    options = pg.GateOptions(profile=profile, **kwargs)
    plan = pg.load_plan(fixture, ignore_noise=options.ignore_noise)
    return pg.evaluate(plan, options)


def minimal_plan(entries: list[dict[str, Any]], **extra: Any) -> dict[str, Any]:
    """A plan document with only what parse_plan needs, for in-memory cases."""
    doc: dict[str, Any] = {
        "format_version": "1.2",
        "terraform_version": "1.9.8",
        "planned_values": {"root_module": {}},
        "resource_changes": entries,
    }
    doc.update(extra)
    return doc


def entry(address: str, actions: list[str], **change: Any) -> dict[str, Any]:
    """A managed resource_changes entry with the given actions."""
    body: dict[str, Any] = {
        "actions": actions,
        "before": change.pop("before", {}),
        "after": change.pop("after", {}),
        "after_unknown": change.pop("after_unknown", {}),
        "before_sensitive": {},
        "after_sensitive": {},
    }
    body.update(change)
    return {"address": address, "mode": "managed", "change": body}


# ---------------------------------------------------------------------------
# Classification, noise, and parsing
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("actions", "kind"),
    [
        (["no-op"], pg.KIND_NO_OP),
        (["create"], pg.KIND_CREATE),
        (["update"], pg.KIND_UPDATE),
        (["delete"], pg.KIND_DELETE),
        (["delete", "create"], pg.KIND_REPLACE),
        (["create", "delete"], pg.KIND_REPLACE),
        (["read"], pg.KIND_READ),
        (["forget"], pg.KIND_FORGET),
        (["update", "create"], pg.KIND_UNKNOWN),
        ([], pg.KIND_UNKNOWN),
    ],
)
def test_classify_actions_exactly_as_terraform_emits(actions: list[str], kind: str) -> None:
    assert pg.classify_actions(actions) == kind


def test_normalize_value_applies_the_three_noise_rules() -> None:
    assert pg.normalize_value("text\n") == "text"
    assert pg.normalize_value("text\r\n") == "text"
    assert pg.normalize_value("") is None
    assert pg.normalize_value("\n") is None
    assert pg.normalize_value({"b": 1, "a": 2}) == {"a": 2, "b": 1}
    assert list(pg.normalize_value({"b": 1, "a": 2})) == ["a", "b"]
    # List order is a real change, not noise.
    assert pg.normalize_value([1, 2]) != pg.normalize_value([2, 1])


def test_is_noise_only_accepts_noise_and_rejects_real_differences() -> None:
    before = {"description": "x\n", "note": "", "tags": {"a": "1", "b": "2"}}
    after = {"tags": {"b": "2", "a": "1"}, "note": None, "description": "x"}
    assert pg.is_noise_only(before, after, {})
    assert not pg.is_noise_only(before, {**after, "description": "y"}, {})
    # Anything unknown after apply cannot be called noise.
    assert not pg.is_noise_only(before, after, {"tags": True})
    assert not pg.is_noise_only(before, after, {"nested": [{"deep": True}]})
    # A create or a delete has null on one side and is never noise.
    assert not pg.is_noise_only(None, after, {})


def test_changed_attribute_names_are_names_only_and_sorted() -> None:
    before = {"z": "1", "a": "old", "same": "x"}
    after = {"z": "2", "a": "new", "same": "x", "added": "v"}
    assert pg.changed_attribute_names(before, after) == ("a", "added", "z")
    assert pg.changed_attribute_names(None, after) == ()


def test_parse_plan_rejects_a_state_document() -> None:
    data = json.loads(NOT_A_PLAN.read_text(encoding="utf-8"))
    with pytest.raises(pg.PlanError, match="plan file was expected, not state"):
        pg.parse_plan(data, "not_a_plan.json")


def test_parse_plan_rejects_unsupported_format_version() -> None:
    with pytest.raises(pg.PlanError, match="unsupported format_version"):
        pg.parse_plan(minimal_plan([], format_version="2.0"), "future.json")


def test_parse_plan_rejects_missing_format_version_and_bad_entries() -> None:
    with pytest.raises(pg.PlanError, match="no format_version"):
        pg.parse_plan({"resource_changes": []}, "x.json")
    with pytest.raises(pg.PlanError, match="has no actions array"):
        pg.parse_plan(minimal_plan([{"address": "a.b", "change": {"before": {}}}]), "x.json")
    with pytest.raises(pg.PlanError, match="has no address"):
        pg.parse_plan(minimal_plan([{"change": {"actions": ["no-op"]}}]), "x.json")
    with pytest.raises(pg.PlanError, match="top level is not a JSON object"):
        pg.parse_plan([], "x.json")


def test_parse_plan_tolerates_an_omitted_resource_changes_list() -> None:
    plan = pg.parse_plan({"format_version": "1.2", "planned_values": {}}, "empty.json")
    assert plan.changes == ()
    assert plan.drift == ()
    assert plan.terraform_version == "unknown"


def test_load_plan_errors_are_plan_errors(tmp_path: Path) -> None:
    with pytest.raises(pg.PlanError, match="cannot read plan file"):
        pg.load_plan(tmp_path / "missing.json")
    with pytest.raises(pg.PlanError, match="not valid JSON"):
        pg.load_plan(MALFORMED)


def test_load_plan_reads_utf16_and_utf8_bom(tmp_path: Path) -> None:
    text = ADOPTION_CLEAN.read_text(encoding="utf-8")
    utf16 = tmp_path / "plan-utf16.json"
    utf16.write_bytes(text.encode("utf-16"))
    bom = tmp_path / "plan-bom.json"
    bom.write_bytes(text.encode("utf-8-sig"))
    assert pg.count_entries(pg.load_plan(utf16)).imports == 3
    assert pg.count_entries(pg.load_plan(bom)).imports == 3


def test_import_is_counted_apart_from_actions() -> None:
    plan = pg.load_plan(ADOPTION_STRAY)
    by_address = {e.address: e for e in plan.changes}
    stray = by_address[STRAY_ADDRESS]
    assert stray.importing and stray.kind == pg.KIND_UPDATE
    assert stray.changed_attributes == ("description",)
    counts = pg.count_entries(plan)
    assert (counts.imports, counts.update, counts.no_op, counts.read) == (3, 1, 2, 1)


def test_data_reads_are_neutral_in_every_profile() -> None:
    read_only = minimal_plan(
        [
            {
                "address": "module.x.data.azuread_group.by_display_name[\"g\"]",
                "mode": "data",
                "change": {"actions": ["read"], "before": None, "after": {}, "after_unknown": {}},
            }
        ]
    )
    plan = pg.parse_plan(read_only, "reads.json")
    for profile, kwargs in (
        (pg.PROFILE_ADOPTION, {"expected_imports": 0}),
        (pg.PROFILE_CONVERGENCE, {}),
        (pg.PROFILE_SCOPED_REPLACE, {"allow_patterns": pg.compile_patterns(["nothing"])}),
        (pg.PROFILE_REPORT, {}),
    ):
        result = pg.evaluate(plan, pg.GateOptions(profile=profile, **kwargs))
        assert result.ok, profile
        assert result.counts.read == 1


def test_forget_and_unknown_actions_never_pass_a_gate() -> None:
    plan = pg.parse_plan(
        minimal_plan(
            [
                entry("module.x.aws_iam_role.gone", ["forget"]),
                entry("module.x.aws_iam_role.odd", ["update", "create"]),
            ]
        ),
        "forget.json",
    )
    counts = pg.count_entries(plan)
    assert (counts.forget, counts.unknown) == (1, 1)
    for profile in (pg.PROFILE_ADOPTION, pg.PROFILE_CONVERGENCE):
        result = pg.evaluate(plan, pg.GateOptions(profile=profile, expected_imports=0))
        assert not result.ok
        assert {f.address for f in result.findings} == {
            "module.x.aws_iam_role.gone",
            "module.x.aws_iam_role.odd",
        }
    # An allowlist that covers the whole module admits the forget, which is a
    # change it names, and still refuses the unknown array: no profile allows it.
    scoped = pg.evaluate(
        plan,
        pg.GateOptions(profile=pg.PROFILE_SCOPED_REPLACE, allow_patterns=pg.compile_patterns([r"module\.x\..*"])),
    )
    assert not scoped.ok
    assert [f.address for f in scoped.findings] == ["module.x.aws_iam_role.odd"]
    assert "unknown actions array" in scoped.findings[0].message
    assert [e.address for e in scoped.allowed] == ["module.x.aws_iam_role.gone"]
    assert "(unknown)" in plan.changes[1].describe()


def test_errored_plan_fails_every_gate_but_not_report() -> None:
    plan = pg.parse_plan(minimal_plan([], errored=True), "errored.json")
    for profile in (pg.PROFILE_ADOPTION, pg.PROFILE_CONVERGENCE):
        result = pg.evaluate(plan, pg.GateOptions(profile=profile, expected_imports=0))
        assert not result.ok
        assert "errored" in result.findings[0].message
    assert pg.evaluate(plan, pg.GateOptions(profile=pg.PROFILE_REPORT)).ok


# ---------------------------------------------------------------------------
# adoption
# ---------------------------------------------------------------------------


def test_adoption_clean_with_three_imports_passes() -> None:
    result = gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=3)
    assert result.ok
    assert result.status == pg.STATUS_PASS
    assert result.findings == []
    c = result.counts
    assert (c.no_op, c.imports, c.read, c.changes, c.drift) == (3, 3, 1, 0, 0)


def test_adoption_stray_update_fails_on_that_address_only() -> None:
    result = gate(pg.PROFILE_ADOPTION, ADOPTION_STRAY, expected_imports=3)
    assert not result.ok
    assert result.status == pg.STATUS_FAIL
    assert [f.address for f in result.findings] == [STRAY_ADDRESS]
    message = result.findings[0].message
    assert message.startswith("update while importing, differs on: description")
    assert "disagree with the live object" in message


def test_adoption_expected_imports_exact_and_minimum() -> None:
    assert not gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=4).ok
    assert not gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=2).ok
    assert gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=2, imports_minimum=True).ok
    assert gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=3, imports_minimum=True).ok
    short = gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=4, imports_minimum=True)
    assert not short.ok
    assert "at least 4" in short.findings[0].message


def test_adoption_without_expectation_warns_on_zero_imports() -> None:
    result = gate(pg.PROFILE_ADOPTION, CONVERGENCE_CLEAN)
    assert result.ok
    assert [f.severity for f in result.findings] == [pg.SEVERITY_WARN]
    assert "imports.tf" in result.findings[0].message


def test_adoption_refuses_replace_create_and_delete() -> None:
    result = gate(pg.PROFILE_ADOPTION, REPLACE_ACTIONS, expected_imports=0)
    assert not result.ok
    assert len(result.findings) == 2
    assert all("adoption allows only no-op" in f.message for f in result.findings)


# ---------------------------------------------------------------------------
# convergence
# ---------------------------------------------------------------------------


def test_convergence_clean_passes() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, CONVERGENCE_CLEAN)
    assert result.ok and result.findings == []
    assert result.counts.no_op == 2 and result.counts.imports == 0


def test_convergence_fails_on_import_blocks_left_behind() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, ADOPTION_CLEAN)
    assert not result.ok
    assert len(result.findings) == 3
    assert all("no import blocks" in f.message for f in result.findings)


def test_convergence_fails_on_update() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, ADOPTION_STRAY)
    assert not result.ok
    assert STRAY_ADDRESS in {f.address for f in result.findings}


def test_convergence_fails_on_both_replace_orderings() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, REPLACE_ACTIONS)
    assert not result.ok
    assert result.counts.replace == 2
    assert result.counts.create == 0 and result.counts.delete == 0
    texts = [f.message for f in result.findings]
    assert any(t.startswith("create,delete (replace)") for t in texts)
    assert any(t.startswith("delete,create (replace)") for t in texts)


def test_convergence_reports_drift_without_failing() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, CONVERGENCE_DRIFT)
    assert result.ok
    assert result.counts.drift == 1
    assert [e.address for e in result.drift_entries] == [DRIFT_ADDRESS]
    assert result.drift_entries[0].changed_attributes == ("schedule",)
    assert result.drift_entries[0].source == pg.SOURCE_DRIFT


def test_convergence_fails_on_drift_when_asked() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, CONVERGENCE_DRIFT, fail_on_drift=True)
    assert not result.ok
    assert result.findings[0].address == DRIFT_ADDRESS
    assert result.findings[0].message.startswith("drift: update, differs on: schedule")


# ---------------------------------------------------------------------------
# scoped-replace
# ---------------------------------------------------------------------------


def test_scoped_replace_allowed_passes_and_lists_the_allowed_change() -> None:
    result = gate(
        pg.PROFILE_SCOPED_REPLACE, SCOPED_ALLOWED, allow_patterns=pg.compile_patterns([RULE_PATTERN])
    )
    assert result.ok
    assert [e.address for e in result.allowed] == [RULE_ADDRESS]
    assert result.counts.replace == 1


def test_scoped_replace_violation_fails_only_on_the_unlisted_address() -> None:
    result = gate(
        pg.PROFILE_SCOPED_REPLACE, SCOPED_VIOLATION, allow_patterns=pg.compile_patterns([RULE_PATTERN])
    )
    assert not result.ok
    assert [f.address for f in result.findings] == [ZONE_ADDRESS]
    assert "not in the allowlist" in result.findings[0].message
    assert [e.address for e in result.allowed] == [RULE_ADDRESS]


def test_scoped_replace_pattern_must_match_the_whole_address() -> None:
    substring = pg.compile_patterns(["module.session_policy"])
    assert not gate(pg.PROFILE_SCOPED_REPLACE, SCOPED_ALLOWED, allow_patterns=substring).ok
    whole_module = pg.compile_patterns([r"module\.session_policy\..*"])
    assert gate(pg.PROFILE_SCOPED_REPLACE, SCOPED_ALLOWED, allow_patterns=whole_module).ok


def test_scoped_replace_imports_need_an_allowlist_match_too() -> None:
    one = pg.compile_patterns([r'module\.custom_roles\.azurerm_role_definition\.this\["pim-operator"\]'])
    result = gate(pg.PROFILE_SCOPED_REPLACE, ADOPTION_CLEAN, allow_patterns=one)
    assert not result.ok
    assert len(result.findings) == 2 and len(result.allowed) == 1
    everything = pg.compile_patterns([r"module\.custom_roles\..*"])
    assert gate(pg.PROFILE_SCOPED_REPLACE, ADOPTION_CLEAN, allow_patterns=everything).ok


def test_scoped_replace_without_patterns_is_an_input_error() -> None:
    with pytest.raises(pg.PlanError, match="needs at least one --allow"):
        gate(pg.PROFILE_SCOPED_REPLACE, SCOPED_ALLOWED)


def test_scoped_replace_allows_both_replace_orderings_by_pattern() -> None:
    patterns = pg.compile_patterns(
        [r"module\.permission_sets\..*", r"module\.account_assignments\..*"]
    )
    result = gate(pg.PROFILE_SCOPED_REPLACE, REPLACE_ACTIONS, allow_patterns=patterns)
    assert result.ok and len(result.allowed) == 2


# ---------------------------------------------------------------------------
# noise
# ---------------------------------------------------------------------------


def test_noise_counts_as_updates_without_the_flag() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, NOISE_ONLY)
    assert not result.ok
    assert result.counts.update == 3 and result.counts.noise == 0


def test_noise_is_ignored_with_the_flag() -> None:
    result = gate(pg.PROFILE_CONVERGENCE, NOISE_ONLY, ignore_noise=True)
    assert result.ok
    c = result.counts
    assert (c.update, c.no_op, c.noise) == (0, 3, 3)
    assert len(result.noise_entries) == 3
    assert all(e.effective_kind == pg.KIND_NO_OP and e.kind == pg.KIND_UPDATE for e in result.noise_entries)


def test_ignore_noise_does_not_hide_a_real_update() -> None:
    result = gate(pg.PROFILE_ADOPTION, ADOPTION_STRAY, expected_imports=3, ignore_noise=True)
    assert not result.ok
    assert result.counts.noise == 0


def test_ignore_noise_applies_to_drift_as_well() -> None:
    drifted = entry("module.x.azuread_group.this[\"g\"]", ["update"], before={"description": "a\n"}, after={"description": "a"})
    doc = minimal_plan([], resource_drift=[drifted])
    strict = pg.evaluate(pg.parse_plan(doc, "d.json"), pg.GateOptions(pg.PROFILE_CONVERGENCE, fail_on_drift=True))
    assert not strict.ok and strict.counts.drift == 1
    lenient = pg.evaluate(
        pg.parse_plan(doc, "d.json", ignore_noise=True),
        pg.GateOptions(pg.PROFILE_CONVERGENCE, fail_on_drift=True, ignore_noise=True),
    )
    assert lenient.ok
    assert (lenient.counts.drift, lenient.counts.noise) == (0, 1)
    assert lenient.noise_entries[0].source == pg.SOURCE_DRIFT


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------


def test_report_never_fails_and_still_counts() -> None:
    result = gate(pg.PROFILE_REPORT, REPLACE_ACTIONS, fail_on_drift=True)
    assert result.ok and result.status == pg.STATUS_REPORT
    assert result.counts.replace == 2 and result.findings == []
    drift = gate(pg.PROFILE_REPORT, CONVERGENCE_DRIFT, fail_on_drift=True)
    assert drift.ok and drift.counts.drift == 1


# ---------------------------------------------------------------------------
# CLI: exit codes, output, summaries
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("argv", "code"),
    [
        (["adoption", str(ADOPTION_CLEAN), "--expected-imports", "3"], 0),
        (["adoption", str(ADOPTION_CLEAN), "--expected-imports", "2+"], 0),
        (["adoption", str(ADOPTION_STRAY), "--expected-imports", "3"], 1),
        (["adoption", str(ADOPTION_CLEAN), "--expected-imports", "4"], 1),
        (["convergence", str(CONVERGENCE_CLEAN)], 0),
        (["convergence", str(CONVERGENCE_DRIFT)], 0),
        (["convergence", str(CONVERGENCE_DRIFT), "--fail-on-drift"], 1),
        (["convergence", str(REPLACE_ACTIONS)], 1),
        (["convergence", str(NOISE_ONLY)], 1),
        (["convergence", str(NOISE_ONLY), "--ignore-noise"], 0),
        (["scoped-replace", str(SCOPED_ALLOWED), "--allow", RULE_PATTERN], 0),
        (["scoped-replace", str(SCOPED_VIOLATION), "--allow", RULE_PATTERN], 1),
        (["report", str(REPLACE_ACTIONS)], 0),
        (["report", str(CONVERGENCE_DRIFT), "--fail-on-drift"], 0),
        (["convergence", str(CONVERGENCE_CLEAN), str(ADOPTION_STRAY)], 1),
        (["convergence", str(MALFORMED)], 2),
        (["convergence", str(NOT_A_PLAN)], 2),
        (["convergence", str(FIXTURES / "does-not-exist.json")], 2),
        (["scoped-replace", str(SCOPED_ALLOWED)], 2),
        (["scoped-replace", str(SCOPED_ALLOWED), "--allow", "("], 2),
        (["convergence", str(CONVERGENCE_CLEAN), "--expected-imports", "3"], 2),
        (["adoption", str(ADOPTION_CLEAN), "--allow", "x"], 2),
    ],
)
def test_cli_exit_codes(argv: list[str], code: int, capsys: pytest.CaptureFixture[str]) -> None:
    assert pg.main(argv) == code
    captured = capsys.readouterr()
    if code == 2:
        assert captured.err.startswith("plan_gate: error:")
    else:
        assert "result:" in captured.out


def test_cli_argparse_errors_exit_2(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as bad_profile:
        pg.main(["nope", str(CONVERGENCE_CLEAN)])
    assert bad_profile.value.code == 2
    with pytest.raises(SystemExit) as bad_count:
        pg.main(["adoption", str(ADOPTION_CLEAN), "--expected-imports", "three"])
    assert bad_count.value.code == 2
    assert "expected an integer" in capsys.readouterr().err
    with pytest.raises(SystemExit) as help_exit:
        pg.main(["--help"])
    assert help_exit.value.code == 0
    assert "scoped-replace" in capsys.readouterr().out


def test_cli_allowlist_file_forms(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    as_list = tmp_path / "allow-list.json"
    as_list.write_text(json.dumps([RULE_PATTERN]), encoding="utf-8")
    as_object = tmp_path / "allow-object.json"
    as_object.write_text(json.dumps({"allow": [RULE_PATTERN]}), encoding="utf-8")
    bad = tmp_path / "allow-bad.json"
    bad.write_text(json.dumps({"allow": "not a list"}), encoding="utf-8")
    assert pg.main(["scoped-replace", str(SCOPED_ALLOWED), "--allowlist", str(as_list)]) == 0
    assert pg.main(["scoped-replace", str(SCOPED_ALLOWED), "--allowlist", str(as_object)]) == 0
    assert pg.main(["scoped-replace", str(SCOPED_ALLOWED), "--allowlist", str(bad)]) == 2
    assert "allowlist must be a JSON list" in capsys.readouterr().err
    assert pg.main(["scoped-replace", str(SCOPED_ALLOWED), "--allowlist", str(tmp_path / "none.json")]) == 2


def test_summary_table_and_details(capsys: pytest.CaptureFixture[str]) -> None:
    assert pg.main(["adoption", str(ADOPTION_CLEAN), str(ADOPTION_STRAY), "--expected-imports", "3"]) == 1
    out = capsys.readouterr().out
    assert out.startswith("plan_gate adoption\n")
    header = "plan                           result  no-op  create  update  delete  replace  read  imports  drift  noise"
    assert header in out
    assert re.search(r"adoption_clean_3_imports\.json\s+PASS\s+3\s+0\s+0\s+0\s+0\s+1\s+3\s+0\s+0\n", out)
    assert re.search(r"adoption_stray_update\.json\s+FAIL\s+2\s+0\s+1\s+0\s+0\s+1\s+3\s+0\s+0\n", out)
    assert f"{ADOPTION_CLEAN}: PASS\n  - nothing to report" in out
    assert f"{ADOPTION_STRAY}: FAIL\n  - {STRAY_ADDRESS}: update while importing" in out
    assert out.rstrip().endswith("result: FAIL (1 of 2 plan(s) passed)")


def test_summary_sections_for_drift_noise_and_allowed(capsys: pytest.CaptureFixture[str]) -> None:
    pg.main(["convergence", str(CONVERGENCE_DRIFT)])
    out = capsys.readouterr().out
    assert "  drift (reported apart from the changes; gated only with --fail-on-drift):\n" in out
    assert f"  - {DRIFT_ADDRESS}: update, differs on: schedule" in out
    pg.main(["convergence", str(NOISE_ONLY), "--ignore-noise"])
    out = capsys.readouterr().out
    assert "  noise ignored:\n" in out
    assert "azuread_group.this[\"grp-pim-readers\"]: update, differs on: description" in out
    pg.main(["scoped-replace", str(SCOPED_ALLOWED), "--allow", RULE_PATTERN])
    out = capsys.readouterr().out
    assert "  allowed by the allowlist:\n" in out
    assert f"  - {RULE_ADDRESS}: delete,create (replace), differs on:" in out
    pg.main(["report", str(REPLACE_ACTIONS)])
    out = capsys.readouterr().out
    assert "REPORT" in out
    assert out.rstrip().endswith("result: REPORT (1 plan(s), no gate)")


def test_warning_lines_are_marked_and_do_not_fail(capsys: pytest.CaptureFixture[str]) -> None:
    assert pg.main(["adoption", str(CONVERGENCE_CLEAN)]) == 0
    out = capsys.readouterr().out
    assert "  - warning: no import blocks in this plan" in out
    assert "result: PASS (1 of 1 plan(s) passed)" in out


def test_json_output_goes_to_stdout_and_summary_to_stderr(capsys: pytest.CaptureFixture[str]) -> None:
    code = pg.main(["adoption", str(ADOPTION_STRAY), "--expected-imports", "3", "--json", "--title", "corp/azure-rbac-roles"])
    assert code == 1
    captured = capsys.readouterr()
    doc = json.loads(captured.out)
    assert doc["tool"] == "plan_gate" and doc["version"] == pg.__version__
    assert doc["title"] == "corp/azure-rbac-roles"
    assert doc["profile"] == "adoption" and doc["ok"] is False and doc["exit_code"] == 1
    plan = doc["plans"][0]
    assert plan["plan"] == "adoption_stray_update.json"
    assert plan["path"] == str(ADOPTION_STRAY)
    assert plan["terraform_version"] == "1.9.8" and plan["format_version"] == "1.2"
    assert plan["status"] == "FAIL"
    assert plan["counts"] == {
        "no_op": 2, "create": 0, "update": 1, "delete": 0, "replace": 0, "read": 1,
        "forget": 0, "unknown": 0, "imports": 3, "drift": 0, "noise": 0,
    }
    assert plan["findings"][0]["address"] == STRAY_ADDRESS
    assert plan["findings"][0]["severity"] == "fail"
    # Only entries that say something are listed: the three imports, not the data read.
    assert {e["address"] for e in plan["changes"]} == {
        STRAY_ADDRESS,
        'module.custom_roles.azurerm_role_definition.this["pim-operator"]',
        'module.custom_roles.azurerm_role_definition.this["reader-plus"]',
    }
    assert captured.err.startswith("corp/azure-rbac-roles\n")


def test_no_attribute_values_or_import_ids_are_ever_printed(capsys: pytest.CaptureFixture[str]) -> None:
    pg.main(["adoption", str(ADOPTION_STRAY), "--expected-imports", "3", "--json"])
    captured = capsys.readouterr()
    everything = captured.out + captured.err
    assert "reads PIM settings" not in everything
    assert "roleDefinitions/44444444" not in everything
    assert "11111111-1111-1111-1111-111111111111" not in everything


def test_markdown_table_shape() -> None:
    results = [gate(pg.PROFILE_ADOPTION, ADOPTION_CLEAN, expected_imports=3)]
    text = pg.format_markdown(results, "adoption: corp/azure-rbac-roles")
    lines = text.splitlines()
    assert lines[0] == "### adoption: corp/azure-rbac-roles"
    assert lines[2] == "| Plan | Result | No-op | Create | Update | Delete | Replace | Read | Imports | Drift | Noise |"
    assert lines[3] == "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    assert lines[4] == "| adoption_clean_3_imports.json | PASS | 3 | 0 | 0 | 0 | 0 | 1 | 3 | 0 | 0 |"
    assert f"**{ADOPTION_CLEAN}: PASS**" in lines
    assert text.endswith("result: PASS (1 of 1 plan(s) passed)\n")


def test_github_summary_appends_to_the_named_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    summary = tmp_path / "step-summary.md"
    summary.write_text("### earlier step\n\n", encoding="utf-8")
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    code = pg.main(
        ["adoption", str(ADOPTION_CLEAN), "--expected-imports", "3", "--github-summary", "--title", "adoption: corp/azure-rbac-roles"]
    )
    assert code == 0
    first = summary.read_text(encoding="utf-8")
    assert first.startswith("### earlier step\n\n### adoption: corp/azure-rbac-roles\n")
    assert "| adoption_clean_3_imports.json | PASS |" in first
    assert "GITHUB_STEP_SUMMARY" not in capsys.readouterr().err

    code = pg.main(["convergence", str(ADOPTION_STRAY), "--github-summary"])
    assert code == 1
    second = summary.read_text(encoding="utf-8")
    assert second.startswith(first)
    assert "### plan_gate convergence" in second
    assert f"- `{STRAY_ADDRESS}`: update while importing" in second


def test_github_summary_without_the_variable_says_so(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    assert pg.main(["convergence", str(CONVERGENCE_CLEAN), "--github-summary"]) == 0
    captured = capsys.readouterr()
    assert "GITHUB_STEP_SUMMARY is not set" in captured.err
    assert "result: PASS" in captured.out
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", "")
    assert pg.write_github_summary("x\n") is None


def test_write_github_summary_uses_the_given_environ(tmp_path: Path) -> None:
    target = tmp_path / "s.md"
    written = pg.write_github_summary("no trailing newline", {"GITHUB_STEP_SUMMARY": str(target)})
    assert written == target
    assert target.read_text(encoding="utf-8") == "no trailing newline\n"


def test_script_runs_as_a_file(tmp_path: Path) -> None:
    env_free = {"PYTHONDONTWRITEBYTECODE": "1"}
    helped = subprocess.run(
        [sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True, check=False, cwd=str(tmp_path), env={**dict(**_clean_env()), **env_free}
    )
    assert helped.returncode == 0
    assert "adoption" in helped.stdout and "exit codes" in helped.stdout
    ran = subprocess.run(
        [sys.executable, str(SCRIPT), "adoption", str(ADOPTION_CLEAN), "--expected-imports", "3"],
        capture_output=True, text=True, check=False, cwd=str(tmp_path), env={**dict(**_clean_env()), **env_free},
    )
    assert ran.returncode == 0
    assert "result: PASS" in ran.stdout
    failed = subprocess.run(
        [sys.executable, str(SCRIPT), "convergence", str(ADOPTION_STRAY)],
        capture_output=True, text=True, check=False, cwd=str(tmp_path), env={**dict(**_clean_env()), **env_free},
    )
    assert failed.returncode == 1


def _clean_env() -> dict[str, str]:
    """The current environment without GITHUB_STEP_SUMMARY, so a runner's file is not touched."""
    import os

    return {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}


def test_tool_tree_is_ascii_only() -> None:
    offenders = []
    for path in TOOL_DIR.rglob("*"):
        if path.suffix not in (".py", ".md", ".json") or "__pycache__" in path.parts:
            continue
        raw = path.read_bytes()
        if any(byte > 127 for byte in raw):
            offenders.append(path.name)
    assert offenders == []
