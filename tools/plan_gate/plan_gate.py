#!/usr/bin/env python3
"""Gate a Terraform plan on what it is allowed to change.

What this is
------------
``plan_gate`` reads one or more plan files rendered with ``terraform show -json``
(``terragrunt show -json`` in this repository) and holds every entry of
``resource_changes`` to a named profile. It is the zero-change import gate from
``tests/README.md`` as a program instead of a jq snippet, with two more
profiles for the plans that come after adoption and a report mode that only
counts.

Contract
--------
Input
    Plan JSON with ``format_version`` 1.x (Terraform 1.9 writes 1.2). State
    JSON, a document that is not JSON, or an entry without an actions array
    is an input error. UTF-8 with or without a BOM and UTF-16 (what a Windows
    PowerShell 5.1 redirect writes) are both read.

Counting
    Each entry is classified by its ``actions`` array exactly as Terraform
    emits it: ``["no-op"]``, ``["create"]``, ``["update"]``, ``["delete"]``,
    ``["delete", "create"]`` and ``["create", "delete"]`` (both are a
    replace), ``["read"]``, and ``["forget"]`` (a ``removed`` block).
    Anything else is ``unknown`` and never passes a gate.
    ``change.importing`` is counted separately from the actions: an import
    block that agrees with the cell is an importing no-op, one that does not
    is an importing update. Data sources (``mode: data``) and ``read``
    actions are neutral in every profile. Entries under ``resource_drift``
    are counted and listed apart from ``resource_changes`` and fail a gate
    only with ``--fail-on-drift``. A plan whose ``errored`` flag is set fails
    every gating profile.

Profiles
    adoption
        Every non-neutral entry is a no-op, importing or not; nothing is
        created, updated, deleted, replaced, or forgotten; the number of
        importing entries equals ``--expected-imports N`` or is at least
        ``N+``. Without ``--expected-imports`` a plan with no imports passes
        with a warning, because the plan is clean but adopted nothing.
    convergence
        No create, update, delete, replace, or forget, and no import blocks:
        the cell and the tenant agree and ``imports.tf`` has been deleted.
    scoped-replace
        Only addresses that fully match one of the allowlist patterns
        (``--allow REGEX``, repeatable, or ``--allowlist FILE``) may show a
        change or an import; everything else must be a no-op. A pattern has
        to match the whole address so an under-specified pattern fails
        loudly instead of allowing more than was meant.
    report
        No gate. The summary and, with ``--github-summary``, the markdown
        table. Exits 0 unless the input is unusable.

Noise
    With ``--ignore-noise`` an update whose ``before`` and ``after`` differ
    only by a trailing newline, by an empty string against null, or by map
    key order is counted as a no-op and listed under noise. An entry with
    any unknown value in ``after_unknown`` is never noise. The same rule
    applies to drift entries.

Output
    A human summary on stdout: one table for every plan given, then the
    findings, the drift, the noise, and the allowed changes per plan.
    ``--json`` puts a JSON document on stdout instead and moves the human
    summary to stderr. ``--github-summary`` appends a markdown table to the
    file named by ``GITHUB_STEP_SUMMARY`` when that variable is set. Only
    addresses, actions, and attribute names are ever printed: never
    attribute values, import IDs, or anything from ``before`` or ``after``.

Exit codes
    0   every plan passed its profile (report always passes)
    1   at least one plan has a failing finding
    2   usage or input error: an unreadable or malformed plan, a file that
        is not a plan, a bad pattern or allowlist, an option the profile
        does not take, or scoped-replace without an allowlist

Library use
    ``load_plan``, ``evaluate``, ``format_summary``, ``format_markdown``,
    ``results_to_dict``, and ``write_github_summary`` are the public
    surface; ``main`` wires them to argparse.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

__version__ = "1.0.0"

EXIT_PASS = 0
EXIT_FINDINGS = 1
EXIT_USAGE = 2

PROFILE_ADOPTION = "adoption"
PROFILE_CONVERGENCE = "convergence"
PROFILE_SCOPED_REPLACE = "scoped-replace"
PROFILE_REPORT = "report"
PROFILES: tuple[str, ...] = (
    PROFILE_ADOPTION,
    PROFILE_CONVERGENCE,
    PROFILE_SCOPED_REPLACE,
    PROFILE_REPORT,
)

KIND_NO_OP = "no-op"
KIND_CREATE = "create"
KIND_UPDATE = "update"
KIND_DELETE = "delete"
KIND_REPLACE = "replace"
KIND_READ = "read"
KIND_FORGET = "forget"
KIND_UNKNOWN = "unknown"

# The actions arrays Terraform emits, exactly, and the kind each one is. The
# two replace orderings differ only in create_before_destroy and are one kind.
ACTION_KINDS: Mapping[tuple[str, ...], str] = {
    ("no-op",): KIND_NO_OP,
    ("create",): KIND_CREATE,
    ("update",): KIND_UPDATE,
    ("delete",): KIND_DELETE,
    ("delete", "create"): KIND_REPLACE,
    ("create", "delete"): KIND_REPLACE,
    ("read",): KIND_READ,
    ("forget",): KIND_FORGET,
}

SOURCE_CHANGES = "resource_changes"
SOURCE_DRIFT = "resource_drift"

SEVERITY_FAIL = "fail"
SEVERITY_WARN = "warn"

STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_REPORT = "REPORT"

TABLE_COLUMNS: tuple[str, ...] = (
    "plan",
    "result",
    "no-op",
    "create",
    "update",
    "delete",
    "replace",
    "read",
    "imports",
    "drift",
    "noise",
)


class PlanError(ValueError):
    """An input the gate cannot evaluate. ``main`` maps it to exit code 2."""


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Entry:
    """One resource_changes or resource_drift entry, reduced to what a gate needs.

    The before and after values are deliberately not kept. The gate decides on
    actions, addresses, and attribute names, so nothing it holds and nothing it
    prints can leak a value.
    """

    address: str
    mode: str
    actions: tuple[str, ...]
    kind: str
    importing: bool
    action_reason: str | None
    changed_attributes: tuple[str, ...]
    noise: bool
    source: str

    @property
    def effective_kind(self) -> str:
        """The kind after noise suppression: a noise-only update is a no-op."""
        return KIND_NO_OP if self.noise else self.kind

    @property
    def neutral(self) -> bool:
        """True for data sources and read actions, which no profile gates."""
        return self.mode == "data" or self.kind == KIND_READ

    @property
    def actions_text(self) -> str:
        """The actions array as Terraform prints it, with the kind when that adds information."""
        text = ",".join(self.actions)
        if self.kind in (KIND_REPLACE, KIND_UNKNOWN):
            text = f"{text} ({self.kind})"
        return text

    def describe(self) -> str:
        """One line for summaries: actions, whether importing, and the attribute names that differ."""
        text = self.actions_text
        if self.importing:
            text = f"{text} while importing"
        if self.changed_attributes:
            text = f"{text}, differs on: {', '.join(self.changed_attributes)}"
        return text

    def to_dict(self) -> dict[str, Any]:
        """The JSON shape of an entry for --json consumers."""
        return {
            "address": self.address,
            "mode": self.mode,
            "actions": list(self.actions),
            "kind": self.kind,
            "effective_kind": self.effective_kind,
            "importing": self.importing,
            "action_reason": self.action_reason,
            "changed_attributes": list(self.changed_attributes),
            "noise": self.noise,
            "source": self.source,
        }


@dataclass
class Counts:
    """Per-plan tallies.

    The kind buckets count the effective kind of each resource_changes entry.
    imports, drift, and noise are counted separately because each answers a
    different question: how many objects are being adopted, how many moved
    outside Terraform, and how many differences were waved through.
    """

    no_op: int = 0
    create: int = 0
    update: int = 0
    delete: int = 0
    replace: int = 0
    read: int = 0
    forget: int = 0
    unknown: int = 0
    imports: int = 0
    drift: int = 0
    noise: int = 0

    def add_kind(self, kind: str) -> None:
        """Increment the bucket for one effective kind."""
        attr = kind.replace("-", "_")
        setattr(self, attr, getattr(self, attr) + 1)

    @property
    def changes(self) -> int:
        """Everything a strict profile refuses: create, update, delete, replace, forget, unknown."""
        return self.create + self.update + self.delete + self.replace + self.forget + self.unknown

    def to_dict(self) -> dict[str, int]:
        """The JSON shape of the counts."""
        return {
            "no_op": self.no_op,
            "create": self.create,
            "update": self.update,
            "delete": self.delete,
            "replace": self.replace,
            "read": self.read,
            "forget": self.forget,
            "unknown": self.unknown,
            "imports": self.imports,
            "drift": self.drift,
            "noise": self.noise,
        }


@dataclass(frozen=True)
class Plan:
    """A parsed plan document: its identity, its changes, and its drift."""

    name: str
    path: str
    terraform_version: str
    format_version: str
    errored: bool
    changes: tuple[Entry, ...]
    drift: tuple[Entry, ...]


@dataclass(frozen=True)
class Finding:
    """One reason a plan fails (severity fail) or one thing worth saying (warn)."""

    severity: str
    address: str | None
    message: str

    def to_dict(self) -> dict[str, Any]:
        """The JSON shape of a finding."""
        return {"severity": self.severity, "address": self.address, "message": self.message}


@dataclass(frozen=True)
class GateOptions:
    """Everything a profile needs beyond the plan itself."""

    profile: str
    expected_imports: int | None = None
    imports_minimum: bool = False
    allow_patterns: tuple[re.Pattern[str], ...] = ()
    fail_on_drift: bool = False
    ignore_noise: bool = False


@dataclass
class Result:
    """The outcome of one plan under one profile."""

    plan: Plan
    profile: str
    counts: Counts
    findings: list[Finding] = field(default_factory=list)
    allowed: list[Entry] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True when no finding has severity fail; warnings do not fail a gate."""
        return not any(f.severity == SEVERITY_FAIL for f in self.findings)

    @property
    def status(self) -> str:
        """PASS or FAIL for a gating profile, REPORT when nothing was gated."""
        if self.profile == PROFILE_REPORT:
            return STATUS_REPORT
        return STATUS_PASS if self.ok else STATUS_FAIL

    @property
    def drift_entries(self) -> list[Entry]:
        """Drift that is real, that is, not suppressed as noise."""
        return [e for e in self.plan.drift if not e.noise]

    @property
    def noise_entries(self) -> list[Entry]:
        """Every entry, changed or drifted, that --ignore-noise waved through."""
        return [e for e in (*self.plan.changes, *self.plan.drift) if e.noise]

    def to_dict(self) -> dict[str, Any]:
        """The JSON shape of a result; only entries that say something are included."""
        return {
            "plan": self.plan.name,
            "path": self.plan.path,
            "terraform_version": self.plan.terraform_version,
            "format_version": self.plan.format_version,
            "errored": self.plan.errored,
            "profile": self.profile,
            "status": self.status,
            "ok": self.ok,
            "counts": self.counts.to_dict(),
            "findings": [f.to_dict() for f in self.findings],
            "changes": [
                e.to_dict()
                for e in self.plan.changes
                if not e.neutral and (e.effective_kind != KIND_NO_OP or e.importing or e.noise)
            ],
            "drift": [e.to_dict() for e in self.plan.drift],
            "allowed": [e.address for e in self.allowed],
        }


# ---------------------------------------------------------------------------
# Classification and noise
# ---------------------------------------------------------------------------


def classify_actions(actions: Sequence[str]) -> str:
    """Map an actions array to a kind, exactly as Terraform emits it.

    Unknown arrays are not guessed at: a gate that guessed would pass an
    action it had never seen.
    """
    return ACTION_KINDS.get(tuple(actions), KIND_UNKNOWN)


def normalize_value(value: Any) -> Any:
    """Canonicalise a before or after value for the noise comparison.

    Trailing newlines are stripped, an empty string becomes null, and map keys
    are sorted. List order is kept, because Terraform emits sets as lists in
    a stable order and a real change can be a reorder inside a list block.
    """
    if isinstance(value, str):
        stripped = value.rstrip("\r\n")
        return None if stripped == "" else stripped
    if isinstance(value, Mapping):
        return {
            str(k): normalize_value(v)
            for k, v in sorted(value.items(), key=lambda kv: str(kv[0]))
        }
    if isinstance(value, list):
        return [normalize_value(v) for v in value]
    return value


def has_unknown(after_unknown: Any) -> bool:
    """True when any leaf of an after_unknown structure is true.

    Terraform replaces unknown leaves with true and omits known ones, so any
    true anywhere means the after value cannot be compared with before.
    """
    if after_unknown is True:
        return True
    if isinstance(after_unknown, Mapping):
        return any(has_unknown(v) for v in after_unknown.values())
    if isinstance(after_unknown, list):
        return any(has_unknown(v) for v in after_unknown)
    return False


def is_noise_only(before: Any, after: Any, after_unknown: Any = None) -> bool:
    """True when before and after differ only by the noise rules.

    Only object values compare; a create or delete has null on one side and
    is never noise. Any unknown in after means the answer is not knowable
    until apply, which is not noise either.
    """
    if not isinstance(before, Mapping) or not isinstance(after, Mapping):
        return False
    if has_unknown(after_unknown):
        return False
    return normalize_value(before) == normalize_value(after)


def changed_attribute_names(before: Any, after: Any) -> tuple[str, ...]:
    """The top-level attribute names whose raw values differ, sorted.

    Names, never values: this is what the summary prints beside an address so
    a reader knows which cell value to look at.
    """
    if not isinstance(before, Mapping) or not isinstance(after, Mapping):
        return ()
    names = sorted(set(before) | set(after), key=str)
    return tuple(str(n) for n in names if before.get(n) != after.get(n))


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def parse_entry(raw: Any, source: str, ignore_noise: bool = False) -> Entry:
    """Reduce one raw resource_changes or resource_drift entry to an Entry.

    Anything without an address, a change object, or an actions array is an
    input error rather than a silent skip: a gate must not pass over an entry
    it could not read.
    """
    if not isinstance(raw, Mapping) or not isinstance(raw.get("address"), str):
        raise PlanError(f"{source}: an entry has no address")
    address = raw["address"]
    change = raw.get("change")
    if not isinstance(change, Mapping):
        raise PlanError(f"{source}: {address} has no change object")
    actions_raw = change.get("actions")
    if not isinstance(actions_raw, list) or not all(isinstance(a, str) for a in actions_raw):
        raise PlanError(f"{source}: {address} has no actions array")
    actions = tuple(actions_raw)
    kind = classify_actions(actions)
    before = change.get("before")
    after = change.get("after")
    changed = changed_attribute_names(before, after) if kind in (KIND_UPDATE, KIND_REPLACE) else ()
    noise = bool(
        ignore_noise
        and kind == KIND_UPDATE
        and is_noise_only(before, after, change.get("after_unknown"))
    )
    reason = raw.get("action_reason")
    return Entry(
        address=address,
        mode=str(raw.get("mode", "managed")),
        actions=actions,
        kind=kind,
        importing=isinstance(change.get("importing"), Mapping),
        action_reason=reason if isinstance(reason, str) else None,
        changed_attributes=changed,
        noise=noise,
        source=source,
    )


def _entries(raw: Any, source: str, ignore_noise: bool) -> tuple[Entry, ...]:
    """Parse one of the two entry lists; a missing list is empty, anything else is an error."""
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise PlanError(f"{source} is not a list")
    return tuple(parse_entry(item, source, ignore_noise) for item in raw)


def parse_plan(data: Any, name: str, ignore_noise: bool = False, path: str | None = None) -> Plan:
    """Turn a decoded plan document into a Plan, refusing what is not a plan.

    A state document also carries format_version, so the check is for the
    keys only a plan has. Terraform omits resource_changes when it is empty,
    which is why planned_values and configuration are accepted as evidence.
    """
    if not isinstance(data, Mapping):
        raise PlanError(f"{name}: the top level is not a JSON object")
    format_version = data.get("format_version")
    if not isinstance(format_version, str):
        raise PlanError(f"{name}: no format_version; not a terraform show -json document")
    if format_version.split(".")[0] != "1":
        raise PlanError(f"{name}: unsupported format_version {format_version} (expected 1.x)")
    plan_keys = ("resource_changes", "resource_drift", "planned_values", "configuration")
    if not any(key in data for key in plan_keys):
        raise PlanError(
            f"{name}: no resource_changes or planned_values; a plan file was expected, not state"
        )
    return Plan(
        name=name,
        path=path if path is not None else name,
        terraform_version=str(data.get("terraform_version", "unknown")),
        format_version=format_version,
        errored=bool(data.get("errored", False)),
        changes=_entries(data.get("resource_changes"), SOURCE_CHANGES, ignore_noise),
        drift=_entries(data.get("resource_drift"), SOURCE_DRIFT, ignore_noise),
    )


def _read_text(path: Path) -> str:
    """Read a plan file whatever encoding the shell that redirected it chose.

    Windows PowerShell 5.1 writes UTF-16 with a BOM on redirect; everything
    else writes UTF-8, sometimes with a BOM. Both are accepted so the same
    command works on a runner and on a workstation.
    """
    raw = path.read_bytes()
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16")
    return raw.decode("utf-8-sig")


def load_plan(path: Path, ignore_noise: bool = False) -> Plan:
    """Read and parse one plan file; every failure is a PlanError with the path in it."""
    try:
        text = _read_text(path)
    except OSError as exc:
        raise PlanError(f"{path}: cannot read plan file ({exc.strerror or exc})") from exc
    try:
        data = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PlanError(f"{path}: not valid JSON ({exc})") from exc
    return parse_plan(data, path.name, ignore_noise=ignore_noise, path=str(path))


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------


def count_entries(plan: Plan) -> Counts:
    """Tally a plan: effective kinds and imports from changes, drift and noise from both lists."""
    counts = Counts()
    for entry in plan.changes:
        counts.add_kind(entry.effective_kind)
        if entry.importing:
            counts.imports += 1
        if entry.noise:
            counts.noise += 1
    for entry in plan.drift:
        if entry.noise:
            counts.noise += 1
        else:
            counts.drift += 1
    return counts


def _fail(entry: Entry, reason: str) -> Finding:
    """A failing finding for one entry, in the one-line shape the summary prints."""
    return Finding(SEVERITY_FAIL, entry.address, f"{entry.describe()}; {reason}")


def _gate_adoption(plan: Plan, counts: Counts, options: GateOptions) -> list[Finding]:
    """Adoption: everything is a no-op, and the import count is the one expected."""
    findings: list[Finding] = []
    for entry in plan.changes:
        if entry.neutral or entry.effective_kind == KIND_NO_OP:
            continue
        if entry.importing:
            findings.append(_fail(entry, "the cell values disagree with the live object"))
        else:
            findings.append(_fail(entry, "adoption allows only no-op entries"))
    if options.expected_imports is None:
        if counts.imports == 0:
            findings.append(
                Finding(
                    SEVERITY_WARN,
                    None,
                    "no import blocks in this plan; is imports.tf present in the cell?",
                )
            )
    elif options.imports_minimum:
        if counts.imports < options.expected_imports:
            findings.append(
                Finding(
                    SEVERITY_FAIL,
                    None,
                    f"{counts.imports} import(s) in the plan, at least {options.expected_imports} expected",
                )
            )
    elif counts.imports != options.expected_imports:
        findings.append(
            Finding(
                SEVERITY_FAIL,
                None,
                f"{counts.imports} import(s) in the plan, exactly {options.expected_imports} expected",
            )
        )
    return findings


def _gate_convergence(plan: Plan) -> list[Finding]:
    """Convergence: nothing changes and nothing is being imported."""
    findings: list[Finding] = []
    for entry in plan.changes:
        if entry.neutral:
            continue
        if entry.importing:
            findings.append(
                _fail(
                    entry,
                    "convergence expects no import blocks: delete imports.tf after the first apply",
                )
            )
        elif entry.effective_kind != KIND_NO_OP:
            findings.append(_fail(entry, "convergence expects no-op"))
    return findings


def _gate_scoped_replace(plan: Plan, options: GateOptions, allowed: list[Entry]) -> list[Finding]:
    """Scoped replace: only allowlisted addresses may change or import."""
    if not options.allow_patterns:
        raise PlanError("scoped-replace needs at least one --allow pattern or an --allowlist file")
    findings: list[Finding] = []
    for entry in plan.changes:
        if entry.neutral:
            continue
        if entry.effective_kind == KIND_NO_OP and not entry.importing:
            continue
        if entry.kind == KIND_UNKNOWN:
            # An allowlist says which addresses may change, not that an
            # action this gate has never seen is a change it understands.
            findings.append(_fail(entry, "unknown actions array; no profile allows it"))
            continue
        if any(pattern.fullmatch(entry.address) for pattern in options.allow_patterns):
            allowed.append(entry)
            continue
        findings.append(_fail(entry, "address is not in the allowlist"))
    return findings


def _drift_findings(result_drift: Sequence[Entry], options: GateOptions) -> list[Finding]:
    """Drift fails only when asked; otherwise it is listed and left alone."""
    if not options.fail_on_drift:
        return []
    return [
        Finding(SEVERITY_FAIL, entry.address, f"drift: {entry.describe()}; --fail-on-drift")
        for entry in result_drift
    ]


def evaluate(plan: Plan, options: GateOptions) -> Result:
    """Hold one plan to one profile and return the counts and the findings.

    The profile decides which entries are refused; the errored flag and drift
    are shared by every gating profile and skipped by report, which never
    fails.
    """
    counts = count_entries(plan)
    result = Result(plan=plan, profile=options.profile, counts=counts)
    if options.profile == PROFILE_ADOPTION:
        result.findings.extend(_gate_adoption(plan, counts, options))
    elif options.profile == PROFILE_CONVERGENCE:
        result.findings.extend(_gate_convergence(plan))
    elif options.profile == PROFILE_SCOPED_REPLACE:
        result.findings.extend(_gate_scoped_replace(plan, options, result.allowed))
    elif options.profile != PROFILE_REPORT:
        raise PlanError(f"unknown profile {options.profile!r}; one of {', '.join(PROFILES)}")
    if options.profile != PROFILE_REPORT:
        if plan.errored:
            result.findings.insert(
                0,
                Finding(SEVERITY_FAIL, None, "the plan errored; Terraform did not finish planning"),
            )
        result.findings.extend(_drift_findings(result.drift_entries, options))
    return result


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def _table_rows(results: Sequence[Result]) -> list[list[str]]:
    """One row per plan in TABLE_COLUMNS order."""
    rows: list[list[str]] = []
    for result in results:
        c = result.counts
        rows.append(
            [
                result.plan.name,
                result.status,
                str(c.no_op),
                str(c.create),
                str(c.update),
                str(c.delete),
                str(c.replace),
                str(c.read),
                str(c.imports),
                str(c.drift),
                str(c.noise),
            ]
        )
    return rows


def render_table(headers: Sequence[str], rows: Sequence[Sequence[str]], markdown: bool = False) -> str:
    """Render a table as aligned text or as GitHub markdown.

    The first two columns are text and left-aligned; the rest are counts and
    right-aligned, so a column of zeros reads as a column of zeros.
    """
    if markdown:
        lines = [
            "| " + " | ".join(headers) + " |",
            "|" + "|".join("---" if i < 2 else "---:" for i in range(len(headers))) + "|",
        ]
        lines.extend("| " + " | ".join(row) + " |" for row in rows)
        return "\n".join(lines)
    widths = [
        max([len(header)] + [len(row[i]) for row in rows]) for i, header in enumerate(headers)
    ]

    def fmt(cells: Sequence[str]) -> str:
        parts = []
        for i, cell in enumerate(cells):
            parts.append(cell.ljust(widths[i]) if i < 2 else cell.rjust(widths[i]))
        return "  ".join(parts).rstrip()

    return "\n".join([fmt(headers)] + [fmt(row) for row in rows])


def _overall_line(results: Sequence[Result]) -> str:
    """The last line of the summary: the aggregate the exit code is taken from."""
    total = len(results)
    if results and all(r.profile == PROFILE_REPORT for r in results):
        return f"result: {STATUS_REPORT} ({total} plan(s), no gate)"
    passed = sum(1 for r in results if r.ok)
    status = STATUS_PASS if passed == total else STATUS_FAIL
    return f"result: {status} ({passed} of {total} plan(s) passed)"


def _detail_lines(result: Result, markdown: bool) -> list[str]:
    """The per-plan block under the table: findings, allowed, drift, noise."""

    def item(address: str | None, text: str) -> str:
        if address is None:
            return f"- {text}"
        return f"- `{address}`: {text}" if markdown else f"- {address}: {text}"

    lines: list[str] = []
    heading = f"{result.plan.path}: {result.status}"
    lines.append(f"**{heading}**" if markdown else heading)
    for finding in result.findings:
        marker = "" if finding.severity == SEVERITY_FAIL else "warning: "
        lines.append(item(finding.address, marker + finding.message))
    if result.allowed:
        lines.append("allowed by the allowlist:")
        lines.extend(item(e.address, e.describe()) for e in result.allowed)
    if result.drift_entries:
        lines.append("drift (reported apart from the changes; gated only with --fail-on-drift):")
        lines.extend(item(e.address, e.describe()) for e in result.drift_entries)
    if result.noise_entries:
        lines.append("noise ignored:")
        lines.extend(
            item(e.address, e.describe() + (" (drift)" if e.source == SOURCE_DRIFT else ""))
            for e in result.noise_entries
        )
    if len(lines) == 1:
        lines.append("- nothing to report" if markdown else "- nothing to report")
    return lines


def format_summary(results: Sequence[Result], title: str) -> str:
    """The human summary: title, one table for every plan, then the details per plan."""
    lines = [title, "", render_table(TABLE_COLUMNS, _table_rows(results)), ""]
    for result in results:
        lines.extend("  " + line if line.startswith("-") or line.endswith(":") else line for line in _detail_lines(result, markdown=False))
        lines.append("")
    lines.append(_overall_line(results))
    return "\n".join(lines) + "\n"


def format_markdown(results: Sequence[Result], title: str) -> str:
    """The GitHub step summary block: a heading, the table, and the details as bullet lists."""
    headers = [h.capitalize() if h != "no-op" else "No-op" for h in TABLE_COLUMNS]
    lines = [f"### {title}", "", render_table(headers, _table_rows(results), markdown=True), ""]
    for result in results:
        lines.extend(_detail_lines(result, markdown=True))
        lines.append("")
    lines.append(_overall_line(results))
    return "\n".join(lines) + "\n"


def results_to_dict(results: Sequence[Result], title: str, exit_code: int) -> dict[str, Any]:
    """The --json document: the aggregate first, then one object per plan."""
    return {
        "tool": "plan_gate",
        "version": __version__,
        "title": title,
        "profile": results[0].profile if results else None,
        "ok": all(r.ok for r in results),
        "exit_code": exit_code,
        "plans": [r.to_dict() for r in results],
    }


def write_github_summary(markdown: str, environ: Mapping[str, str] | None = None) -> Path | None:
    """Append markdown to the GITHUB_STEP_SUMMARY file; None when the variable is unset.

    Appending, not writing, because other steps of the same job add their own
    blocks to the same file.
    """
    env = os.environ if environ is None else environ
    target = env.get("GITHUB_STEP_SUMMARY", "")
    if not target:
        return None
    path = Path(target)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(markdown)
        if not markdown.endswith("\n"):
            handle.write("\n")
    return path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_expected_imports(text: str) -> tuple[int, bool]:
    """Parse N (exact) or N+ (a minimum) for --expected-imports."""
    match = re.fullmatch(r"(\d+)(\+?)", text.strip())
    if match is None:
        raise argparse.ArgumentTypeError(
            f"expected an integer, or an integer followed by + for a minimum, got {text!r}"
        )
    return int(match.group(1)), match.group(2) == "+"


def load_allowlist(path: Path) -> list[str]:
    """Read an allowlist file: a JSON list of patterns, or an object with an allow list."""
    try:
        data = json.loads(_read_text(path))
    except OSError as exc:
        raise PlanError(f"{path}: cannot read allowlist ({exc.strerror or exc})") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PlanError(f"{path}: allowlist is not valid JSON ({exc})") from exc
    if isinstance(data, Mapping):
        data = data.get("allow")
    if not isinstance(data, list) or not all(isinstance(p, str) for p in data):
        raise PlanError(f'{path}: allowlist must be a JSON list of patterns or {{"allow": [...]}}')
    return list(data)


def compile_patterns(patterns: Iterable[str]) -> tuple[re.Pattern[str], ...]:
    """Compile allowlist patterns; a bad one is an input error, not a traceback."""
    compiled: list[re.Pattern[str]] = []
    for pattern in patterns:
        try:
            compiled.append(re.compile(pattern))
        except re.error as exc:
            raise PlanError(f"bad allow pattern {pattern!r}: {exc}") from exc
    return tuple(compiled)


def build_parser() -> argparse.ArgumentParser:
    """The argparse surface; the module docstring is the long form of this help."""
    parser = argparse.ArgumentParser(
        prog="plan_gate",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Hold Terraform plan JSON (terraform show -json <planfile>) to a profile.\n\n"
            "profiles:\n"
            "  adoption        every entry is a no-op, importing or not, and the import\n"
            "                  count matches --expected-imports\n"
            "  convergence     no create, update, delete, replace, or forget, and no imports\n"
            "  scoped-replace  only addresses matching --allow or --allowlist may change\n"
            "  report          no gate; the summary table only"
        ),
        epilog=(
            "exit codes:\n"
            "  0  every plan passed its profile (report always passes)\n"
            "  1  at least one plan has a failing finding\n"
            "  2  usage or input error (unreadable or malformed plan, bad pattern or\n"
            "     allowlist, an option the profile does not take)"
        ),
    )
    parser.add_argument("profile", choices=PROFILES, help="the profile to hold the plan(s) to")
    parser.add_argument(
        "plans", nargs="+", metavar="PLAN", help="plan JSON written by terraform show -json"
    )
    parser.add_argument(
        "--expected-imports",
        type=parse_expected_imports,
        metavar="N[+]",
        help="adoption only: the plan must import exactly N objects, or at least N with a trailing +",
    )
    parser.add_argument(
        "--allow",
        action="append",
        default=[],
        metavar="REGEX",
        help="scoped-replace only: an address pattern that may change (whole-address match); repeatable",
    )
    parser.add_argument(
        "--allowlist",
        type=Path,
        metavar="FILE",
        help='scoped-replace only: a JSON list of patterns, or {"allow": [...]}',
    )
    parser.add_argument(
        "--fail-on-drift",
        action="store_true",
        help="treat resource_drift entries as failing findings (report ignores this)",
    )
    parser.add_argument(
        "--ignore-noise",
        action="store_true",
        help="count an update as a no-op when before and after differ only by a trailing newline, empty string versus null, or map key order",
    )
    parser.add_argument(
        "--json", action="store_true", help="print a JSON document on stdout; the human summary moves to stderr"
    )
    parser.add_argument(
        "--github-summary",
        action="store_true",
        help="append a markdown table to the file named by GITHUB_STEP_SUMMARY when it is set",
    )
    parser.add_argument("--title", metavar="TEXT", help="heading for the summary (default: plan_gate <profile>)")
    parser.add_argument("--version", action="version", version=f"plan_gate {__version__}")
    return parser


def options_from_args(args: argparse.Namespace) -> GateOptions:
    """Turn parsed arguments into GateOptions, refusing options the profile does not take.

    An option that only one profile reads is an error with any other profile
    rather than silently ignored, because a gate invoked with the wrong
    profile should not look like it honoured the option.
    """
    expected = args.expected_imports
    if expected is not None and args.profile != PROFILE_ADOPTION:
        raise PlanError("--expected-imports is only meaningful with the adoption profile")
    patterns: list[str] = list(args.allow)
    if args.allowlist is not None:
        patterns.extend(load_allowlist(args.allowlist))
    if patterns and args.profile != PROFILE_SCOPED_REPLACE:
        raise PlanError("--allow and --allowlist are only meaningful with the scoped-replace profile")
    if args.profile == PROFILE_SCOPED_REPLACE and not patterns:
        raise PlanError("scoped-replace needs at least one --allow pattern or an --allowlist file")
    return GateOptions(
        profile=args.profile,
        expected_imports=expected[0] if expected is not None else None,
        imports_minimum=bool(expected is not None and expected[1]),
        allow_patterns=compile_patterns(patterns),
        fail_on_drift=args.fail_on_drift,
        ignore_noise=args.ignore_noise,
    )


def main(argv: Sequence[str] | None = None) -> int:
    """Run the gate from the command line and return the exit code.

    argparse usage errors exit 2 on their own; input errors are caught here
    and reported on stderr with the same code, so a workflow can tell "the
    plan is red" (1) from "the gate could not run" (2).
    """
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        options = options_from_args(args)
        results = [
            evaluate(load_plan(Path(plan_path), ignore_noise=options.ignore_noise), options)
            for plan_path in args.plans
        ]
    except PlanError as exc:
        print(f"plan_gate: error: {exc}", file=sys.stderr)
        return EXIT_USAGE

    exit_code = EXIT_PASS if all(r.ok for r in results) else EXIT_FINDINGS
    title = args.title or f"plan_gate {options.profile}"
    human = format_summary(results, title)
    if args.json:
        print(json.dumps(results_to_dict(results, title, exit_code), indent=2))
        print(human, file=sys.stderr, end="")
    else:
        print(human, end="")
    if args.github_summary:
        written = write_github_summary(format_markdown(results, title))
        if written is None:
            print(
                "plan_gate: GITHUB_STEP_SUMMARY is not set; no step summary written",
                file=sys.stderr,
            )
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
