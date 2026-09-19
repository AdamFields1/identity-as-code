"""Cell discovery, change selection, and wave ordering for the tenant tree.

Contract
--------
A cell is a directory under ``tenants/`` that holds a ``terragrunt.hcl``.
It is found by that file and never by depth (ADR 0017): ``corp/azure-rbac-roles``
is a cell, so is ``corp/subscriptions/sub-example-prod/data-pipeline``, and
``subscriptions/`` and ``subscriptions/<sub-name>/`` hold a locator, not a cell.
This module answers three questions about cells without running Terragrunt:

1. What is this cell?  Its family (okta, azure, aws), its tenant or partition,
   the account or subscription it is scoped to if any, the stack it calls,
   and the kind of stack that is: platform, definitions, baseline, catalog,
   or app (README "Three layers"; ADR 0017 "Three kinds of stack").
2. Which cells does a change touch?  Given the changed file paths of a pull
   request or a push, every cell is selected for a documented reason or not
   at all.
3. In what order must the selected cells be applied?  The release trains
   currently carry one hand-written plan and apply job per cell, and ADR 0017
   says a new cell "also needs its two jobs added there". The wave order here
   is the same rules, computed from the tree, so a workflow can run wave 0,
   then wave 1, and so on, with a matrix per wave.

Selection reasons (each one is a rule the repository already states):

  cell-files         a file inside the cell's own directory changed.
  stack              a file inside the stack the cell calls changed.
  module             a file inside a module the stack composes changed; module
                     sources are read from the stack's .tf files, transitively,
                     because a module change is a plan change for every cell
                     of every stack that composes it.
  root               the family's root.hcl changed (state backend, provider
                     generation, adoption hook: identical for every cell).
  locator            a partition.hcl, account.hcl, or subscription.hcl above the
                     cell changed; a locator addresses every cell beneath it
                     (ADR 0017), so an edited locator re-plans those cells.
  automation-assets  automation/lib, automation/runbooks, or policies/ changed
                     and the cell calls the azure-automation stack, which
                     publishes those files as runbooks and variables at plan
                     time (ADR 0013, ADR 0015, README "What it manages").
  all                everything was requested (``--all``).

Wave rules (all within one family; families are independent trains):

  * a Terragrunt ``dependencies`` block is honoured;
  * within one account or subscription: baseline, then catalog
    (``*-workloads``), then app stacks (``stacks/apps/...``), the order both
    release trains state once in their header comment;
  * within one tenant: the definitions cell (``azure-rbac-roles``) before the
    cells that resolve custom roles by name at plan time (``azure-pim-governance``
    and ``azure-automation``; ADR 0005, README "Verification status");
  * within one tenant or partition: tenant-wide cells before the cells scoped to
    one account or subscription, because the trains apply the scoped cells
    after the tenant-wide ones;
  * the first tenant of a family before the gated one (dev then prod, corp then
    subsidiary, commercial then govcloud; README "Promotion is gated").

Two things about a cell are refused before any of that, because a workflow
turns them into names: a directory name on the path to a cell must be made
of letters, digits, dot, hyphen, and underscore (the trains put the cell's
path and id into job names, artifact names, and shell), and the cell's
tenant must be one the family's promotion order names (the trains name their
GitHub environments ``<tenant>-plan``, ``<tenant>``, and ``<tenant>-apply``
from it, and an environment nobody created has no reviewers).

Exit codes: 0 success; 2 usage or input error (no ``tenants/`` directory, a
cell that cannot be read, named with the path, a directory name a workflow
could not use safely, a tenant the promotion order does not name, or a
dependency cycle).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

FAMILIES: tuple[str, ...] = ("okta", "azure", "aws")

# The first tenant of each family is applied on merge; the second waits at a
# gate (README, "Promotion is gated, first tenant before the second").
PROMOTION_ORDER: dict[str, tuple[str, ...]] = {
    "okta": ("dev", "prod"),
    "azure": ("corp", "subsidiary"),
    "aws": ("commercial", "govcloud"),
}

LOCATOR_NAMES: tuple[str, ...] = ("partition.hcl", "account.hcl", "subscription.hcl")

# Directory name under a tenant that introduces a scoped cell, and the scope
# it introduces (ADR 0017).
SCOPE_DIRS: dict[str, str] = {"accounts": "account", "subscriptions": "subscription"}

# Definitions cells and the stacks that resolve those definitions by name at
# plan time (ADR 0005; README "Verification status" names both consumers).
DEFINITION_CONSUMERS: dict[str, tuple[str, ...]] = {
    "azure-rbac-roles": ("azure-pim-governance", "azure-automation"),
}

AUTOMATION_STACK = "azure-automation"
AUTOMATION_ASSET_PREFIXES: tuple[str, ...] = (
    "automation/lib/",
    "automation/runbooks/",
    "policies/",
)

# Apply order of the scoped stack kinds inside one account or subscription.
KIND_ORDER: dict[str, int] = {"baseline": 0, "catalog": 1, "app": 2}

SKIP_DIR_NAMES: frozenset[str] = frozenset(
    {".git", ".terraform", ".terragrunt-cache", "__pycache__", ".pytest_cache"}
)


# ---------------------------------------------------------------------------
# HCL reading.
#
# The tool needs four things from an HCL file: the names of its top-level
# blocks and attributes, ``terraform.source``, ``dependencies.paths``, and the
# string attributes of a ``locals`` block. A tokenizer that skips comments and
# understands strings (including ``${...}`` templates with quotes inside, and
# heredocs) gives those deterministically with the standard library. It is
# not an HCL evaluator and does not try to be.
# ---------------------------------------------------------------------------


class HclSyntaxError(ValueError):
    """Raised when a file cannot be read as HCL well enough to inspect it."""


class CellPathError(ValueError):
    """Raised when a directory name on the path to a cell is one a workflow could not use as a name."""


# What a directory name on the path to a cell may be made of. The release
# trains put a cell's path and id into job names, artifact names, and shell
# words, so a name is data only when it cannot be anything else.
SEGMENT_RE = re.compile(r"^[A-Za-z0-9._-]+$")


@dataclass(frozen=True)
class Token:
    """One lexical token: kind is ident, string, number, punct, newline, or heredoc."""

    kind: str
    text: str
    line: int


@dataclass(frozen=True)
class Raw:
    """An attribute value that is not a plain string or list.

    Function calls, references, numbers, and objects are kept as their source
    text so a caller can say exactly what it refused instead of guessing.
    """

    text: str


@dataclass
class HclItem:
    """A top-level block or attribute with the tokens of its body."""

    name: str
    kind: str
    labels: tuple[str, ...]
    tokens: list[Token]
    line: int


_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_\-]*")
_NUMBER_RE = re.compile(r"[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
_HEREDOC_RE = re.compile(r"<<-?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\r?\n")
_OPENERS: dict[str, str] = {"{": "}", "[": "]", "(": ")"}
_CLOSERS: frozenset[str] = frozenset(_OPENERS.values())


def _read_string(text: str, start: int, line: int) -> tuple[str, int]:
    """Read a double-quoted HCL string starting at text[start].

    Returns the raw contents (escapes preserved) and the index just past the
    closing quote. Template interpolations ``${...}`` and directives ``%{...}``
    may contain quoted strings of their own, which is why this is not a regex.
    """
    i = start + 1
    depth = 0
    out: list[str] = []
    n = len(text)
    while i < n:
        c = text[i]
        if depth == 0:
            if c == "\\":
                out.append(text[i : i + 2])
                i += 2
                continue
            if c == '"':
                return "".join(out), i + 1
            if c in "$%" and text.startswith(c + "{", i):
                depth = 1
                out.append(text[i : i + 2])
                i += 2
                continue
            out.append(c)
            i += 1
        else:
            if c == '"':
                inner, j = _read_string(text, i, line)
                out.append('"' + inner + '"')
                i = j
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            out.append(c)
            i += 1
    raise HclSyntaxError(f"line {line}: unterminated string")


def tokenize(text: str) -> list[Token]:
    """Split HCL text into tokens, dropping comments and whitespace.

    Newlines are kept as tokens because an attribute value ends at the first
    newline outside brackets, which is the one piece of layout HCL cares about.
    """
    tokens: list[Token] = []
    i = 0
    n = len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == "\n":
            tokens.append(Token("newline", "\n", line))
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if c == "#" or text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise HclSyntaxError(f"line {line}: unterminated block comment")
            line += text.count("\n", i, j)
            i = j + 2
            continue
        if c == '"':
            value, j = _read_string(text, i, line)
            tokens.append(Token("string", value, line))
            line += text.count("\n", i, j)
            i = j
            continue
        if text.startswith("<<", i):
            m = _HEREDOC_RE.match(text, i)
            if m:
                marker = m.group(1)
                k = m.end()
                while True:
                    eol = text.find("\n", k)
                    segment = text[k : n if eol < 0 else eol]
                    if segment.strip() == marker:
                        end = n if eol < 0 else eol
                        break
                    if eol < 0:
                        raise HclSyntaxError(f"line {line}: unterminated heredoc {marker}")
                    k = eol + 1
                tokens.append(Token("heredoc", text[m.end() : k], line))
                line += text.count("\n", i, end)
                i = end
                continue
        m = _IDENT_RE.match(text, i)
        if m:
            tokens.append(Token("ident", m.group(0), line))
            i = m.end()
            continue
        m = _NUMBER_RE.match(text, i)
        if m:
            tokens.append(Token("number", m.group(0), line))
            i = m.end()
            continue
        tokens.append(Token("punct", c, line))
        i += 1
    return tokens


def _matching(tokens: Sequence[Token], i: int) -> int:
    """Return the index of the bracket that closes the opener at tokens[i]."""
    stack = [_OPENERS[tokens[i].text]]
    j = i + 1
    while j < len(tokens):
        t = tokens[j]
        if t.kind == "punct":
            if t.text in _OPENERS:
                stack.append(_OPENERS[t.text])
            elif t.text in _CLOSERS:
                if t.text != stack[-1]:
                    raise HclSyntaxError(f"line {t.line}: unexpected {t.text!r}")
                stack.pop()
                if not stack:
                    return j
        j += 1
    raise HclSyntaxError(f"line {tokens[i].line}: unclosed {tokens[i].text!r}")


def parse_items(tokens: Sequence[Token]) -> list[HclItem]:
    """Split a token stream into blocks and attributes at its own top level.

    Works on a whole file and on the body of a block alike, so callers can
    descend one level when they need to (``terraform { source = ... }``).
    """
    items: list[HclItem] = []
    i = 0
    n = len(tokens)
    while i < n:
        t = tokens[i]
        if t.kind == "newline":
            i += 1
            continue
        if t.kind != "ident":
            raise HclSyntaxError(
                f"line {t.line}: expected a block or attribute name, found {t.text!r}"
            )
        name, line = t.text, t.line
        i += 1
        labels: list[str] = []
        while i < n and tokens[i].kind == "string":
            labels.append(tokens[i].text)
            i += 1
        if i < n and tokens[i].kind == "punct" and tokens[i].text == "{":
            j = _matching(tokens, i)
            items.append(HclItem(name, "block", tuple(labels), list(tokens[i + 1 : j]), line))
            i = j + 1
            continue
        if i < n and tokens[i].kind == "punct" and tokens[i].text == "=" and not labels:
            i += 1
            start = i
            depth = 0
            while i < n:
                tk = tokens[i]
                if tk.kind == "newline" and depth == 0:
                    break
                if tk.kind == "punct":
                    if tk.text in _OPENERS:
                        depth += 1
                    elif tk.text in _CLOSERS:
                        depth -= 1
                        if depth < 0:
                            raise HclSyntaxError(f"line {tk.line}: unexpected {tk.text!r}")
                i += 1
            items.append(HclItem(name, "attribute", (), list(tokens[start:i]), line))
            continue
        raise HclSyntaxError(f"line {line}: expected '{{' or '=' after {name!r}")
    return items


def _split_commas(tokens: Sequence[Token]) -> list[list[Token]]:
    """Split list contents at the commas of their own level, dropping empties."""
    parts: list[list[Token]] = [[]]
    depth = 0
    for t in tokens:
        if t.kind == "newline":
            continue
        if t.kind == "punct":
            if t.text in _OPENERS:
                depth += 1
            elif t.text in _CLOSERS:
                depth -= 1
            elif t.text == "," and depth == 0:
                parts.append([])
                continue
        parts[-1].append(t)
    return [p for p in parts if p]


def value_of(tokens: Sequence[Token]) -> "str | list | Raw":
    """Turn an attribute's value tokens into a string, a list, or Raw text."""
    body = [t for t in tokens if t.kind != "newline"]
    if len(body) == 1 and body[0].kind == "string":
        return body[0].text
    if body and body[0].kind == "punct" and body[0].text == "[" and _matching(body, 0) == len(body) - 1:
        return [value_of(part) for part in _split_commas(body[1:-1])]
    return Raw(" ".join(t.text for t in body))


def attributes(tokens: Sequence[Token]) -> dict[str, "str | list | Raw"]:
    """The attributes of a block body by name; nested blocks are ignored."""
    return {it.name: value_of(it.tokens) for it in parse_items(tokens) if it.kind == "attribute"}


def unquote(value: str) -> str:
    """Resolve the two escapes a path or a name could plausibly carry."""
    return value.replace('\\"', '"').replace("\\\\", "\\")


def read_hcl(path: Path) -> list[HclItem]:
    """Tokenize and split one file; the file is read as UTF-8 with replacement."""
    return parse_items(tokenize(path.read_text(encoding="utf-8", errors="replace")))


# ---------------------------------------------------------------------------
# Cells.
# ---------------------------------------------------------------------------


@dataclass
class Cell:
    """One stack applied for one tenant, described from its path and its file."""

    path: str
    family: str
    tenant: str
    scope: str
    scope_name: str | None
    stack: str | None
    stack_name: str
    kind: str
    dependencies: list[str] = field(default_factory=list)
    source: str | None = None

    @property
    def family_path(self) -> str:
        """The cell relative to tenants/<family>, the path the workflows use."""
        parts = self.path.split("/")
        return "/".join(parts[2:])

    @property
    def id(self) -> str:
        """A filesystem-safe id, the same one the workflows derive for artifacts."""
        return self.family_path.replace("/", "-")

    @property
    def gated(self) -> bool:
        """True when the cell belongs to a tenant that waits at the release gate."""
        order = PROMOTION_ORDER.get(self.family)
        return bool(order) and self.tenant != order[0]

    def tenant_rank(self) -> int:
        """Position in the promotion order; unknown tenants follow the known ones and share a rank."""
        order = PROMOTION_ORDER.get(self.family, ())
        if self.tenant in order:
            return order.index(self.tenant)
        return len(order)

    def to_dict(self) -> dict:
        """The matrix entry a workflow reads; every field is a plain JSON value."""
        return {
            "path": self.path,
            "family_path": self.family_path,
            "id": self.id,
            "family": self.family,
            "tenant": self.tenant,
            "scope": self.scope,
            "scope_name": self.scope_name,
            "stack": self.stack,
            "stack_name": self.stack_name,
            "kind": self.kind,
            "gated": self.gated,
            "depends_on": list(self.dependencies),
        }


def _posix(path: Path) -> str:
    return path.as_posix()


def resolve_under_root(base_dir: Path, relative: str, root: Path) -> str | None:
    """Resolve a relative HCL path against its file's directory, as a root-relative posix path."""
    candidate = Path(os.path.normpath(base_dir / relative))
    try:
        return _posix(candidate.relative_to(root))
    except ValueError:
        return None


def classify_stack(stack: str | None, stack_name: str) -> str:
    """Name the kind of stack a cell calls (ADR 0017), from its path and name."""
    if stack and stack.startswith("stacks/apps/"):
        return "app"
    if stack_name in DEFINITION_CONSUMERS:
        return "definitions"
    if stack_name.endswith("-baseline"):
        return "baseline"
    if stack_name.endswith("-workloads"):
        return "catalog"
    return "platform"


def find_cell_files(root: Path) -> list[Path]:
    """Every terragrunt.hcl under tenants/, skipping caches; sorted for determinism."""
    tenants = root / "tenants"
    if not tenants.is_dir():
        return []
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(tenants):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIR_NAMES and not d.startswith("."))
        if "terragrunt.hcl" in filenames:
            found.append(Path(dirpath) / "terragrunt.hcl")
    return sorted(found)


def load_cell(root: Path, hcl_path: Path) -> Cell:
    """Describe one cell from its path in the tree and the blocks in its file.

    A syntax error is re-raised with the file named, so a tree with one broken
    cell says which one. A directory name outside ``SEGMENT_RE`` is refused
    before the file is read: a workflow would turn it into a job name and a
    shell word.
    """
    cell_dir = hcl_path.parent
    rel = _posix(cell_dir.relative_to(root))
    rel_file = _posix(hcl_path.relative_to(root))
    for segment in rel.split("/"):
        if not SEGMENT_RE.match(segment):
            raise CellPathError(
                f"{rel_file}: directory name {segment!r} is not letters, digits, dot, hyphen, "
                "and underscore only; the workflows use a cell's path as a job name and a shell word"
            )
    try:
        items = read_hcl(hcl_path)
    except HclSyntaxError as exc:
        raise HclSyntaxError(f"{rel_file}: {exc}") from exc
    parts = rel.split("/")
    family = parts[1] if len(parts) > 1 else ""
    tenant = parts[2] if len(parts) > 2 else ""
    scope, scope_name = "tenant", None
    if len(parts) >= 5 and parts[3] in SCOPE_DIRS:
        scope, scope_name = SCOPE_DIRS[parts[3]], parts[4]

    source: str | None = None
    dependencies: list[str] = []
    for it in items:
        if it.kind != "block":
            continue
        if it.name == "terraform":
            value = attributes(it.tokens).get("source")
            if isinstance(value, str):
                source = unquote(value)
        elif it.name == "dependencies":
            value = attributes(it.tokens).get("paths")
            if isinstance(value, list):
                for entry in value:
                    if isinstance(entry, str):
                        resolved = resolve_under_root(cell_dir, unquote(entry), root)
                        if resolved:
                            dependencies.append(resolved)

    stack: str | None = None
    if source and "${" not in source and "://" not in source and not source.startswith("git::"):
        stack = resolve_under_root(cell_dir, source, root)
    if stack:
        stack_name = stack.rstrip("/").rsplit("/", 1)[-1]
    elif source:
        stack_name = source.rstrip("/").rsplit("/", 1)[-1]
    else:
        stack_name = cell_dir.name
    return Cell(
        path=rel,
        family=family,
        tenant=tenant,
        scope=scope,
        scope_name=scope_name,
        stack=stack,
        stack_name=stack_name,
        kind=classify_stack(stack, stack_name),
        dependencies=dependencies,
        source=source,
    )


def discover_cells(root: Path) -> list[Cell]:
    """All cells in the tree, in path order."""
    return [load_cell(root, p) for p in find_cell_files(root)]


def unknown_tenant_lines(cells: Sequence[Cell]) -> list[str]:
    """One message per cell whose family or tenant the promotion order does not name.

    The release trains name their GitHub environments from the tenant
    (``<tenant>-plan``, ``<tenant>``, ``<tenant>-apply``), and an environment
    that was never created is created on first use with no reviewers and no
    branch policy. A new tenant is therefore added to ``PROMOTION_ORDER`` and
    to the repository's environments first, and a cell under any other name
    is refused here so the lint job and the trains see it before a plan runs.
    """
    lines: list[str] = []
    for cell in cells:
        order = PROMOTION_ORDER.get(cell.family)
        if order is None:
            lines.append(
                f"{cell.path}: {cell.family!r} is not a family this tool knows "
                f"({', '.join(PROMOTION_ORDER)}); add it to PROMOTION_ORDER first"
            )
        elif cell.tenant not in order:
            lines.append(
                f"{cell.path}: {cell.tenant!r} is not a tenant of the {cell.family} family "
                f"({', '.join(order)}); the release trains name their environments from the "
                "tenant, so add it to PROMOTION_ORDER and to the repository's environments first"
            )
    return lines


# ---------------------------------------------------------------------------
# Module sources of a stack.
# ---------------------------------------------------------------------------

_MODULE_SOURCE_RE = re.compile(r'^[ \t]*source[ \t]*=[ \t]*"(\.{1,2}/[^"]*)"', re.MULTILINE)


def local_module_sources(tf_dir: Path) -> list[str]:
    """Relative ``source = "./..."`` or ``"../..."`` values in a directory's .tf files.

    Registry and provider sources (``hashicorp/aws``) do not start with a dot
    and are ignored: only a local path is a file in this repository.
    """
    sources: list[str] = []
    if not tf_dir.is_dir():
        return sources
    for tf in sorted(tf_dir.glob("*.tf")):
        text = tf.read_text(encoding="utf-8", errors="replace")
        sources.extend(_MODULE_SOURCE_RE.findall(text))
    return sources


def module_dirs(root: Path, stack: str) -> set[str]:
    """Every local module a stack composes, transitively, as root-relative posix paths."""
    seen: set[str] = set()
    queue = [stack]
    while queue:
        current = queue.pop()
        for src in local_module_sources(root / current):
            resolved = resolve_under_root(root / current, src, root)
            if resolved and resolved not in seen and resolved != stack:
                seen.add(resolved)
                queue.append(resolved)
    return seen


# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Reason:
    """Why a cell was selected: a rule code and the changed path that fired it."""

    code: str
    path: str

    def to_dict(self) -> dict:
        return {"code": self.code, "path": self.path}


def normalize_changed(paths: Iterable[str]) -> list[str]:
    """Posix, no leading ./, no blanks, no duplicates; order preserved."""
    out: list[str] = []
    for p in paths:
        p = p.strip().replace("\\", "/")
        while p.startswith("./"):
            p = p[2:]
        p = p.strip("/")
        if p and p not in out:
            out.append(p)
    return out


def _under(path: str, directory: str) -> bool:
    return path == directory or path.startswith(directory + "/")


def select_cells(
    root: Path,
    cells: Sequence[Cell],
    changed: Sequence[str] | None,
    select_all: bool = False,
) -> dict[str, list[Reason]]:
    """Map each selected cell path to the reasons it was selected.

    Every reason is one of the rules in the module docstring. A cell absent
    from the result was not touched by the change.
    """
    selected: dict[str, list[Reason]] = {}
    if select_all:
        return {c.path: [Reason("all", "")] for c in cells}
    changed_paths = normalize_changed(changed or [])
    module_cache: dict[str, set[str]] = {}
    for cell in cells:
        reasons: list[Reason] = []
        root_hcl = f"tenants/{cell.family}/root.hcl"
        ancestors: list[str] = []
        parts = cell.path.split("/")
        for depth in range(2, len(parts)):
            ancestors.append("/".join(parts[: depth + 1]))
        if cell.stack and cell.stack not in module_cache:
            module_cache[cell.stack] = module_dirs(root, cell.stack)
        modules = module_cache.get(cell.stack or "", set())
        for p in changed_paths:
            if _under(p, cell.path):
                reasons.append(Reason("cell-files", p))
            elif cell.stack and _under(p, cell.stack):
                reasons.append(Reason("stack", p))
            elif any(_under(p, m) for m in modules):
                reasons.append(Reason("module", p))
            elif p == root_hcl:
                reasons.append(Reason("root", p))
            elif any(p == f"{a}/{name}" for a in ancestors for name in LOCATOR_NAMES):
                reasons.append(Reason("locator", p))
            elif cell.stack_name == AUTOMATION_STACK and p.startswith(AUTOMATION_ASSET_PREFIXES):
                reasons.append(Reason("automation-assets", p))
        if reasons:
            selected[cell.path] = reasons
    return selected


# ---------------------------------------------------------------------------
# Waves.
# ---------------------------------------------------------------------------


class CycleError(ValueError):
    """Raised when the ordering rules and dependencies blocks contradict each other."""


def order_waves(cells: Sequence[Cell]) -> list[list[Cell]]:
    """Group cells into waves: every cell's prerequisites are in earlier waves.

    The edges are the rules in the module docstring. Levels are longest-path
    depths, so a cell lands in the earliest wave its prerequisites allow, and
    cells with no relationship share a wave and run in parallel.
    """
    by_path = {c.path: c for c in cells}
    prereqs: dict[str, set[str]] = {c.path: set() for c in cells}

    def before(a: Cell, b: Cell) -> None:
        prereqs[b.path].add(a.path)

    for a in cells:
        for b in cells:
            if a is b or a.family != b.family:
                continue
            if a.tenant == b.tenant:
                same_scope = a.scope == b.scope and a.scope_name == b.scope_name
                if same_scope and a.kind in KIND_ORDER and b.kind in KIND_ORDER:
                    if KIND_ORDER[a.kind] < KIND_ORDER[b.kind]:
                        before(a, b)
                if same_scope and b.stack_name in DEFINITION_CONSUMERS.get(a.stack_name, ()):
                    before(a, b)
                if a.scope == "tenant" and b.scope != "tenant":
                    before(a, b)
            elif a.tenant_rank() < b.tenant_rank():
                before(a, b)
        for dep in a.dependencies:
            if dep in by_path and dep != a.path:
                before(by_path[dep], a)

    dependents: dict[str, set[str]] = defaultdict(set)
    indegree: dict[str, int] = {}
    for path, pre in prereqs.items():
        indegree[path] = len(pre)
        for q in pre:
            dependents[q].add(path)
    level: dict[str, int] = {}
    queue = sorted(p for p, d in indegree.items() if d == 0)
    for p in queue:
        level[p] = 0
    done = 0
    while queue:
        current = queue.pop(0)
        done += 1
        for nxt in sorted(dependents[current]):
            level[nxt] = max(level.get(nxt, 0), level[current] + 1)
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                queue.append(nxt)
    if done != len(cells):
        stuck = sorted(p for p, d in indegree.items() if d > 0)
        raise CycleError("dependency cycle among cells: " + ", ".join(stuck))
    waves: list[list[Cell]] = []
    for path in sorted(level, key=lambda p: (level[p], p)):
        while len(waves) <= level[path]:
            waves.append([])
        waves[level[path]].append(by_path[path])
    return waves


# ---------------------------------------------------------------------------
# Matrix output.
# ---------------------------------------------------------------------------


def build_matrix(
    cells: Sequence[Cell],
    selected: dict[str, list[Reason]],
    pad_waves: int = 0,
) -> dict:
    """The JSON a workflow consumes: one list per wave, and the same lists per family."""
    chosen = [c for c in cells if c.path in selected]
    waves = order_waves(chosen)
    while len(waves) < pad_waves:
        waves.append([])

    def entry(cell: Cell, wave: int) -> dict:
        d = cell.to_dict()
        d["wave"] = wave
        d["reasons"] = [r.to_dict() for r in selected.get(cell.path, [])]
        return d

    wave_lists = [[entry(c, i) for c in wave] for i, wave in enumerate(waves)]
    families: dict[str, list[list[dict]]] = {}
    for fam in sorted({c.family for c in chosen}):
        fam_waves = [[e for e in wave if e["family"] == fam] for wave in wave_lists]
        while fam_waves and not fam_waves[-1] and len(fam_waves) > pad_waves:
            fam_waves.pop()
        families[fam] = fam_waves
    return {
        "wave_count": len(wave_lists),
        "cell_count": len(chosen),
        "waves": wave_lists,
        "wave_sizes": [len(w) for w in wave_lists],
        "families": families,
        "family_wave_sizes": {fam: [len(w) for w in fam_waves] for fam, fam_waves in families.items()},
        "cells": [e for wave in wave_lists for e in wave],
    }


# ---------------------------------------------------------------------------
# Command line.
# ---------------------------------------------------------------------------


def git_diff_names(root: Path, base: str, head: str) -> list[str]:
    """The paths ``git diff --name-only base head`` reports, relative to root."""
    result = subprocess.run(
        ["git", "-C", str(root), "diff", "--name-only", base, head],
        capture_output=True,
        text=True,
        check=True,
    )
    return normalize_changed(result.stdout.splitlines())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cells.py",
        description=(
            "Discover tenant cells, select the ones a change touches, and order "
            "them into waves for a release workflow."
        ),
        epilog=(
            "Exit codes: 0 success; 2 usage or input error (no tenants/ directory, a cell "
            "that cannot be read, a directory name a workflow could not use, a tenant the "
            "promotion order does not name, a dependency cycle). With no selection option "
            "every cell is listed, which is the same as --all."
        ),
    )
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    parser.add_argument(
        "--family",
        action="append",
        choices=FAMILIES,
        help="limit output to one family; repeatable",
    )
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--all", action="store_true", help="select every cell")
    selection.add_argument("--changed", nargs="+", metavar="PATH", help="changed file paths")
    selection.add_argument(
        "--changed-from",
        metavar="FILE",
        help="read changed paths from FILE, one per line; '-' reads standard input",
    )
    selection.add_argument(
        "--diff",
        nargs=2,
        metavar=("BASE", "HEAD"),
        help="changed paths from 'git diff --name-only BASE HEAD'",
    )
    parser.add_argument("--github-matrix", action="store_true", help="print the matrix as one JSON line")
    parser.add_argument("--json", action="store_true", help="print the matrix as indented JSON")
    parser.add_argument("--explain", action="store_true", help="say why each cell was or was not selected")
    parser.add_argument(
        "--pad-waves",
        type=int,
        default=0,
        metavar="N",
        help="emit at least N waves (empty lists) so a workflow with fixed wave jobs can index them",
    )
    return parser


def _explain_lines(cells: Sequence[Cell], selected: dict[str, list[Reason]]) -> list[str]:
    lines: list[str] = []
    for cell in cells:
        reasons = selected.get(cell.path)
        if reasons:
            for r in reasons:
                detail = f" ({r.path})" if r.path else ""
                lines.append(f"{cell.path}: selected, {r.code}{detail}")
        else:
            lines.append(f"{cell.path}: not selected")
    return lines


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point; returns the exit code instead of calling sys.exit."""
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if not (root / "tenants").is_dir():
        print(f"error: {root} has no tenants/ directory", file=sys.stderr)
        return 2
    try:
        cells = discover_cells(root)
    except (HclSyntaxError, CellPathError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.family:
        cells = [c for c in cells if c.family in args.family]
    unknown = unknown_tenant_lines(cells)
    if unknown:
        for line in unknown:
            print(f"error: {line}", file=sys.stderr)
        return 2

    changed: list[str] | None = None
    select_all = args.all
    if args.changed:
        changed = normalize_changed(args.changed)
    elif args.changed_from:
        try:
            if args.changed_from == "-":
                changed = normalize_changed(sys.stdin.read().splitlines())
            else:
                changed = normalize_changed(
                    Path(args.changed_from).read_text(encoding="utf-8").splitlines()
                )
        except OSError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    elif args.diff:
        try:
            changed = git_diff_names(root, args.diff[0], args.diff[1])
        except (subprocess.CalledProcessError, OSError) as exc:
            print(f"error: git diff failed: {exc}", file=sys.stderr)
            return 2
    else:
        select_all = True

    selected = select_cells(root, cells, changed, select_all=select_all)
    try:
        matrix = build_matrix(cells, selected, pad_waves=args.pad_waves)
    except CycleError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.github_matrix:
        print(json.dumps(matrix, separators=(",", ":"), sort_keys=True))
    elif args.json:
        print(json.dumps(matrix, indent=2, sort_keys=True))
    else:
        for i, wave in enumerate(matrix["waves"]):
            print(f"wave {i}")
            for e in wave:
                gate = " gated" if e["gated"] else ""
                print(f"  {e['path']}  [{e['family']}/{e['tenant']} {e['kind']}{gate}]")
        print(f"{matrix['cell_count']} cell(s) in {matrix['wave_count']} wave(s)")
    if args.explain:
        for line in _explain_lines(cells, selected):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
