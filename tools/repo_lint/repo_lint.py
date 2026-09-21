"""repo_lint: enforce the rules this repository writes down about itself.

Contract
--------
The README and the decision records state rules a reviewer is expected to
hold a change to: a cell is values only, a locator is an address and not a
value, every id is a placeholder, nothing in the tree is a secret, the README
names every module and stack, a runbook parameter must bind from a job
schedule string, and the decision records form an index. Each rule is one
named check here, selectable on its own, with the sentence or ADR it comes
from in its docstring. The tool reads files; it never runs Terraform,
Terragrunt, git (beyond ``git ls-files``), or the network.

Checks:

  cell-shape       tenants/**/terragrunt.hcl holds include, terraform (with a
                   source under stacks/ that exists), inputs, and optionally
                   dependencies (whose paths resolve to cells under tenants/);
                   nothing else. Exactly one include is the family root
                   (find_in_parent_folders("root.hcl")); any other include is
                   labeled and names a fragment, a sibling .hcl file by its
                   bare name, that exists. Its directory names are ones a
                   workflow can use as names, and its tenant is one the
                   family's promotion order knows.
  fragment-shape   every .hcl file beside a terragrunt.hcl other than the cell
                   itself holds one inputs attribute and nothing else, parses,
                   and is included by the cell: a fragment is values only,
                   like the cell it belongs to.
  locators         partition.hcl, account.hcl, and subscription.hcl are locals
                   only, sit where ADR 0017 puts them, and say what they must.
  placeholders     account ids are one repeated digit; GUIDs are a repeated
                   digit, all zeros, or a published Microsoft id; hostnames and
                   email addresses use documentation domains.
  ascii            every text file is ASCII; em and en dashes are named.
  no-secrets       no credential with a known shape anywhere (AWS access key
                   ids, private keys, JWTs, Okta, GitHub, and Azure tokens
                   and keys, storage keys, SAS signatures, Slack webhooks),
                   and no assignment of a secret-named variable to a literal
                   outside test files and placeholders.
  readme-tables    every module and stack directory is named in README.md, and
                   every path in the README Layout tree exists.
  runbook-params   a runbook's top-level param block has no [switch] and no
                   array parameter, and the runbook never calls Write-Host.
  adr-index        every docs/adr/NNNN-*.md has Status and Date lines, the
                   numbers are contiguous from 0001, and the title agrees.

Usage: ``repo_lint.py [--root DIR] [--check NAME ...] [--skip NAME ...] [--json]``

Exit codes: 0 every selected check passed; 1 at least one finding;
2 usage or input error (unknown check, root is not a directory, the
allowlist file is malformed). Findings never include the text of anything
the no-secrets check matched.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Sequence

try:
    from . import cells as _cells
except ImportError:  # run as a script: python tools/repo_lint/repo_lint.py
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cells as _cells  # type: ignore[no-redef]

HERE = Path(__file__).resolve().parent
BUILTIN_IDS_FILE = HERE / "microsoft_builtin_ids.txt"

# Paths (posix, root-relative, directory prefixes end with /) that no check
# reads. The linter's own fixture tree holds deliberately bad examples.
DEFAULT_EXCLUDES: tuple[str, ...] = ("tools/repo_lint/tests/fixtures/",)

SKIP_DIR_NAMES = _cells.SKIP_DIR_NAMES | {"node_modules"}

# Domains whose hostnames are placeholders (RFC 2606) or endpoints of the
# vendors the runbooks, providers, and workflows call, with the documentation
# hosts of those vendors that the READMEs link to. A hostname under any of
# these says nothing about an estate. The list is what the tree uses, not
# what a vendor owns: a host that is not here is a finding, and the fix is
# to add the host with the file that needs it, never to widen the rule.
PLACEHOLDER_DOMAINS: tuple[str, ...] = ("example.com", "example.org", "example.net")
VENDOR_DOMAINS: tuple[str, ...] = (
    # Microsoft endpoints (commercial and US Government) and docs
    "microsoft.com",
    "microsoft.us",
    "microsoftonline.com",
    "microsoftonline.us",
    "azure.com",
    "azure.net",
    "azure.us",
    "windows.net",
    "usgovcloudapi.net",
    # AWS endpoints (commercial and GovCloud), the access portal, and docs
    "amazonaws.com",
    "amazonaws-us-gov.com",
    "amazon.com",
    "awsapps.com",
    # Okta cells (commercial, preview, EMEA, and government)
    "okta.com",
    "oktapreview.com",
    "okta-emea.com",
    "okta.mil",
    # GitHub (OIDC issuer, actions, raw files) and HashiCorp (registry, docs)
    "github.com",
    "githubusercontent.com",
    "terraform.io",
    "hashicorp.com",
    # Google Workspace, the gallery vendor tenants/azure/corp/entra-enterprise-apps onboards
    "google.com",
    # SAML claim-type namespace (schemas.xmlsoap.org), the nameidentifier URI in modules/entra/saml-enterprise-app
    "xmlsoap.org",
)
ALLOWED_DOMAINS: tuple[str, ...] = PLACEHOLDER_DOMAINS + VENDOR_DOMAINS

_TLDS = "com|net|org|io|us|gov|ms|cloud|dev|co|uk|edu|mil|info|biz|app|ai"
_GUID_RE = re.compile(
    r"(?<![0-9A-Za-z])([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(?![0-9A-Za-z])"
)
_ACCOUNT_ID_RE = re.compile(r"(?<![0-9A-Za-z])([0-9]{12})(?![0-9A-Za-z])")
_HOST_RE = re.compile(
    r"(?<![A-Za-z0-9._%@-])((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:"
    + _TLDS
    + r"))(?![A-Za-z0-9_\-\[\(])(?!\.[A-Za-z0-9_])"
)
# A Terraform reference such as var.app_name or module.app["x"] is not a host
# even when its attribute happens to be a top-level domain.
_REFERENCE_ROOTS: frozenset[str] = frozenset(
    {"var", "local", "module", "each", "data", "self", "path", "terraform", "count", "output", "resource"}
)
_EMAIL_RE = re.compile(
    r"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+)@((?:[A-Za-z0-9-]+\.)+(?:"
    + _TLDS
    + r"))(?![A-Za-z0-9-])(?!\.[A-Za-z0-9])",
    re.IGNORECASE,
)

# Credentials with a shape of their own. These run over every file, test
# files included, because a shape this specific is a real credential wherever
# it sits; the placeholder words below are the only thing that excuses one.
_SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str], str], ...] = (
    (
        "aws-access-key-id",
        re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"),
        "AWS access key id",
    ),
    (
        "private-key-block",
        re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----"),
        "private key block",
    ),
    (
        # A JWT is two base64url JSON objects and a signature, so its header
        # and its payload both start with eyJ (the encoding of '{"'). A
        # made-up token whose payload is not JSON, which is what a test
        # writes, does not match.
        "jwt",
        re.compile(r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"),
        "JWT-looking string",
    ),
    (
        "okta-ssws-token",
        re.compile(r"\bSSWS\s+[A-Za-z0-9_\-]{20,}"),
        "Okta SSWS API token",
    ),
    (
        # The Okta provider's api_token: 42 characters starting with 00.
        "okta-api-token",
        re.compile(r"(?<![A-Za-z0-9_\-])00[A-Za-z0-9_\-]{40}(?![A-Za-z0-9_\-])"),
        "Okta API token",
    ),
    (
        # Classic (ghp_, gho_, ghu_, ghs_, ghr_) and fine-grained (github_pat_) tokens.
        "github-token",
        re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{82}\b"),
        "GitHub token",
    ),
    (
        # An Entra application client secret: 40 characters with 8Q~ at offset 3.
        "azure-client-secret",
        re.compile(r"(?<![A-Za-z0-9_~.\-])[A-Za-z0-9_~.\-]{3}8Q~[A-Za-z0-9_~.\-]{31,34}(?![A-Za-z0-9_~.\-])"),
        "Azure client secret",
    ),
    (
        # A storage account key inside a connection string: 88 base64 characters.
        "azure-storage-key",
        re.compile(r"AccountKey=[A-Za-z0-9+/]{86}=="),
        "Azure storage account key",
    ),
    (
        # Service Bus and Event Hubs: SharedAccessKey=, never SharedAccessKeyName=.
        "azure-shared-access-key",
        re.compile(r"SharedAccessKey=[A-Za-z0-9+/=]{20,}"),
        "Azure shared access key",
    ),
    (
        # The signature of a shared access signature, in a URL or a token.
        "azure-sas-signature",
        re.compile(r"(?<![A-Za-z0-9_])sig=[A-Za-z0-9%+/=]{40,}"),
        "Azure SAS signature",
    ),
    (
        "slack-webhook",
        re.compile(r"hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+"),
        "Slack webhook URL",
    ),
)

# An assignment of a secret-named variable to a literal. The name is any
# identifier containing one of these words; the value is a quoted string of
# seven or more characters, or a bare word of twelve or more made only of the
# characters a credential is made of (shell exports, INI files, and HCL
# without quotes). A bare value that is a reference, a variable, a URL, or a
# path is not a literal and is skipped in code below.
_SECRET_NAME_WORDS = (
    r"secret|password|passwd|api_key|apikey|token|credential|private_key|access_key"
    r"|account_key|connection_string|sas(?![A-Za-z0-9])"
)
_SECRET_ASSIGN_RE = re.compile(
    r"""(?<![A-Za-z0-9])\$?(?:env:)?["']?
        (?P<name>[A-Za-z0-9_.\-]*(?:""" + _SECRET_NAME_WORDS + r""")[A-Za-z0-9_]*)
        ["']?\s*[:=]\s*
        (?:(?P<quote>["'])(?P<value>[^"'\r\n]{7,})(?P=quote)
          |(?P<bare>[A-Za-z0-9+/=_~.:%@!\-]{11,}[A-Za-z0-9+/=_~%!]))""",
    re.IGNORECASE | re.VERBOSE,
)
_PLACEHOLDER_VALUE_RE = re.compile(
    r"changeme|example|placeholder|redacted|dummy|sample|xxxx|\$\{|\$\(|^<.*>$",
    re.IGNORECASE,
)
# Values that are not literals, quoted or bare: a Terraform reference (var.x,
# local.a.b, module.m.out, each.value.k), a URL, or a path.
_NOT_A_LITERAL_RE = re.compile(
    r"^(?:[A-Za-z][A-Za-z0-9+.\-]*://"
    r"|[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z_][A-Za-z0-9_\-]*)+$"
    r"|(?:[A-Za-z]:)?[\\/]|\.{1,2}[\\/]|~[\\/])"
)
# A value with a variable expansion in it is built at run time ("Bearer $token",
# '{"k":' + (ConvertTo-Json @($x)) + '}'), so it holds no credential of its own.
_EXPANSION_RE = re.compile(r"\$[A-Za-z_{(]|%[A-Za-z_][A-Za-z0-9_]*%")
# Bare values that are code rather than a literal: a PowerShell cmdlet or
# function call (Verb-Noun), and an identifier or a word with no digit in it
# (Environment, check_no_secrets). A credential written bare in a shell
# export or an INI file has digits in it; a passphrase without one is the
# case this rule gives up, and the README says so.
_BARE_CODE_RE = re.compile(r"^(?:[A-Z][A-Za-z]*-[A-Z][A-Za-z0-9]*|[A-Za-z_][A-Za-z_]*)$")
# A quoted value that names an environment variable ('OKTA_API_TOKEN') says
# where a credential lives, which is exactly what the rule asks for.
_QUOTED_NAME_RE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$")

# Test files assign stand-in credentials by construction (a mocked token
# endpoint has to return a string), so the assignment heuristic skips them.
# The shaped detectors above do not: a real client secret or API token pasted
# into a test to reach a live tenant is exactly what they are for.
_TEST_DIR_NAMES: frozenset[str] = frozenset({"tests", "test", "__tests__"})
_TEST_FILE_RES: tuple[re.Pattern[str], ...] = (
    re.compile(r"\.Tests\.ps1$", re.IGNORECASE),
    re.compile(r"^test_.*\.py$"),
    re.compile(r"_test\.py$"),
)


# ---------------------------------------------------------------------------
# Findings and context.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Finding:
    """One rule violation: which check, a stable code, where, and what to do."""

    check: str
    code: str
    path: str
    line: int | None
    message: str

    def to_dict(self) -> dict:
        return {
            "check": self.check,
            "code": self.code,
            "path": self.path,
            "line": self.line,
            "message": self.message,
        }

    def format(self) -> str:
        where = f"{self.path}:{self.line}" if self.line else self.path
        return f"{self.check}  {where}  [{self.code}] {self.message}"


@dataclass
class Context:
    """The tree under inspection: its root and the list of files to read."""

    root: Path
    files: list[str]
    _bytes: dict[str, bytes] = field(default_factory=dict, repr=False)

    def read_bytes(self, rel: str) -> bytes:
        if rel not in self._bytes:
            self._bytes[rel] = (self.root / rel).read_bytes()
        return self._bytes[rel]

    def read_text(self, rel: str) -> str:
        return self.read_bytes(rel).decode("utf-8", errors="replace")

    def is_binary(self, rel: str) -> bool:
        return b"\x00" in self.read_bytes(rel)[:8192]

    def text_files(self) -> list[str]:
        return [f for f in self.files if not self.is_binary(f)]


CheckFn = Callable[[Context], list[Finding]]


def _excluded(rel: str, excludes: Sequence[str]) -> bool:
    for ex in excludes:
        if ex.endswith("/"):
            if rel.startswith(ex):
                return True
        elif rel == ex:
            return True
    return False


def walk_files(root: Path) -> list[str]:
    """Every regular file under root, skipping caches and VCS directories."""
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIR_NAMES)
        for name in sorted(filenames):
            found.append((Path(dirpath) / name).relative_to(root).as_posix())
    return sorted(found)


def git_files(root: Path) -> list[str]:
    """Tracked files plus untracked files git does not ignore, so a new file is checked before it is added."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        check=True,
    )
    names = [n.decode("utf-8", errors="replace") for n in result.stdout.split(b"\0") if n]
    return sorted(n for n in set(names) if (root / n).is_file())


def tracked_files(root: Path, mode: str = "auto", excludes: Sequence[str] = DEFAULT_EXCLUDES) -> list[str]:
    """The files the checks read, as posix paths relative to root.

    ``git`` asks git; ``walk`` walks the tree; ``auto`` asks git when root is
    a repository and walks otherwise (the fixture trees are not repositories).
    """
    use_git = mode == "git" or (mode == "auto" and (root / ".git").exists())
    files: list[str]
    if use_git:
        try:
            files = git_files(root)
        except (OSError, subprocess.CalledProcessError):
            if mode == "git":
                raise
            files = walk_files(root)
    else:
        files = walk_files(root)
    return [
        f
        for f in files
        if not f.startswith(".git/")
        and not any(part in SKIP_DIR_NAMES for part in f.split("/")[:-1])
        and not _excluded(f, excludes)
    ]


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _is_test_path(rel: str) -> bool:
    """True for a file under a tests directory or named like a test; only the assignment heuristic reads this."""
    parts = rel.split("/")
    if any(p in _TEST_DIR_NAMES for p in parts[:-1]):
        return True
    return any(r.search(parts[-1]) for r in _TEST_FILE_RES)


# ---------------------------------------------------------------------------
# cell-shape
# ---------------------------------------------------------------------------

_CELL_ALLOWED: tuple[str, ...] = ("include", "terraform", "inputs", "dependencies")
_CELL_FORBIDDEN: dict[str, str] = {
    "resource": "resource blocks belong in modules/, the only layer that holds one (README, Three layers)",
    "data": "data sources belong in the stack; a cell resolves nothing (ADR 0002)",
    "module": "a cell calls a stack, never a module, so composition never leaks into the tenant layer (README, Three layers)",
    "locals": "a cell holds no locals; a value that needs computing belongs in the stack (ADR 0002)",
    "variable": "a cell declares no variables; it is values only (ADR 0002)",
    "output": "a cell declares no outputs; it is values only (ADR 0002)",
    "provider": "provider configuration is generated once by the family root.hcl (README, Three layers)",
}

# The one include every cell carries: the family root, found by name. The
# tokenizer keeps a string's contents without its quotes, so the Raw text of
# ``find_in_parent_folders("root.hcl")`` reads as below.
_ROOT_INCLUDE_RE = re.compile(r"^find_in_parent_folders \( root\.hcl \)$")
# What a fragment include may name: a sibling file by its bare name, ending in
# .hcl, made of the characters a cell's own directory name may be made of.
_FRAGMENT_NAME_RE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*\.hcl$")


def _is_root_include(value: object) -> bool:
    return isinstance(value, _cells.Raw) and bool(_ROOT_INCLUDE_RE.match(value.text))


def _fragment_name(value: object) -> str | None:
    """The bare sibling file name an include path names, or None when it names anything else."""
    if not isinstance(value, str):
        return None
    name = _cells.unquote(value)
    if "${" in name or not _FRAGMENT_NAME_RE.match(name) or name == "terragrunt.hcl":
        return None
    return name


def _include_findings(ctx: Context, rel: str, includes: list[_cells.HclItem]) -> list[Finding]:
    """The rules about a cell's include blocks.

    A cell includes the family root exactly once, by
    ``find_in_parent_folders("root.hcl")`` under any label. Every other
    include is a fragment: a sibling .hcl file named by its bare name (no
    directory, no template, never terragrunt.hcl) that exists, and that
    ``fragment-shape`` then holds to values only. When a cell carries more
    than one include, every one of them is labeled, which is Terragrunt's
    own rule for a file with several.
    """
    findings: list[Finding] = []
    check = "cell-shape"
    cell_dir = (ctx.root / rel).parent
    roots = 0
    for it in includes:
        if len(includes) > 1 and not it.labels:
            findings.append(Finding(check, "include-unlabeled", rel, it.line, "an include without a label; a cell with more than one include labels every one of them (include \"root\", include \"iam_roles\")"))
        value = _cells.attributes(it.tokens).get("path")
        if _is_root_include(value):
            roots += 1
            if roots == 2:
                findings.append(Finding(check, "include-root-duplicate", rel, it.line, "the family root is included more than once; a cell includes root.hcl exactly once"))
            continue
        name = _fragment_name(value)
        if name is None:
            findings.append(Finding(check, "fragment-include-path", rel, it.line, "an include path is find_in_parent_folders(\"root.hcl\") or the bare name of a sibling .hcl fragment (no directory, no template, not terragrunt.hcl); a fragment sits beside its cell and nowhere else"))
        elif not (cell_dir / name).is_file():
            findings.append(Finding(check, "fragment-missing", rel, it.line, f"include names {name}, which does not exist beside the cell"))
    if includes and roots == 0:
        findings.append(Finding(check, "include-root-missing", rel, includes[0].line, "no include's path is find_in_parent_folders(\"root.hcl\"); every cell includes the family root, which generates its state and provider configuration (ADR 0002)"))
    return findings


def _cell_path_findings(rel: str) -> list[Finding]:
    """The two rules about where a cell sits, not what it holds.

    Its directory names must be ones a workflow can use as a job name and a
    shell word (cells.py refuses anything else with exit 2), and its tenant
    must be one the family's promotion order names, because the release
    trains name their GitHub environments from it and an environment that was
    never created has no reviewers.
    """
    findings: list[Finding] = []
    check = "cell-shape"
    parts = rel.split("/")
    for segment in parts[1:-1]:
        if not _cells.SEGMENT_RE.match(segment):
            findings.append(Finding(check, "path-characters", rel, None, f"directory name {segment!r} is not letters, digits, dot, hyphen, and underscore only; the workflows use a cell's path as a job name and a shell word (docs/adr/0018)"))
    family = parts[1] if len(parts) > 2 else ""
    tenant = parts[2] if len(parts) > 3 else ""
    order = _cells.PROMOTION_ORDER.get(family)
    if order is None:
        findings.append(Finding(check, "tenant-unknown", rel, None, f"{family!r} is not a family cells.py knows ({', '.join(_cells.PROMOTION_ORDER)}); add it to PROMOTION_ORDER first"))
    elif tenant not in order:
        findings.append(Finding(check, "tenant-unknown", rel, None, f"{tenant!r} is not a tenant of the {family} family ({', '.join(order)}); the release trains name their environments from the tenant, so add it to PROMOTION_ORDER in cells.py and to the repository's environments first (README, Promotion is gated)"))
    return findings


def check_cell_shape(ctx: Context) -> list[Finding]:
    """cell-shape: a cell is an include of the root, a source pointing at a stack, and an inputs map, nothing else, with any further include naming a sibling fragment by its bare name, under a tenant the promotion order names and directory names a workflow can use (README "Three layers"; ADR 0002; ADR 0018)."""
    findings: list[Finding] = []
    check = "cell-shape"
    for rel in ctx.text_files():
        if not (rel.startswith("tenants/") and rel.endswith("/terragrunt.hcl")):
            continue
        findings.extend(_cell_path_findings(rel))
        try:
            items = _cells.parse_items(_cells.tokenize(ctx.read_text(rel)))
        except _cells.HclSyntaxError as exc:
            findings.append(Finding(check, "parse-error", rel, None, f"cannot read as HCL: {exc}"))
            continue
        seen: dict[str, int] = {}
        for it in items:
            seen[it.name] = seen.get(it.name, 0) + 1
            if it.name in _CELL_FORBIDDEN:
                findings.append(Finding(check, "forbidden-block", rel, it.line, f"{it.name}: {_CELL_FORBIDDEN[it.name]}"))
            elif it.name not in _CELL_ALLOWED:
                findings.append(
                    Finding(check, "forbidden-block", rel, it.line, f"{it.name} is not one of include, terraform, inputs, dependencies (ADR 0002)")
                )
            elif it.name == "inputs" and it.kind != "attribute":
                findings.append(Finding(check, "inputs-not-attribute", rel, it.line, "inputs must be an attribute (inputs = { ... }), not a block"))
            elif it.name != "inputs" and it.kind != "block":
                findings.append(Finding(check, "not-a-block", rel, it.line, f"{it.name} must be a block, not an attribute"))
            if seen[it.name] == 2 and it.name in _CELL_ALLOWED and it.name != "include":
                findings.append(Finding(check, "duplicate-block", rel, it.line, f"{it.name} appears more than once"))
        for required in ("include", "terraform", "inputs"):
            if required not in seen:
                findings.append(Finding(check, f"missing-{required}", rel, None, f"a cell must have {required} (ADR 0002)"))
        # More than one include is allowed, and each one is either the family
        # root or a fragment beside the cell; _include_findings says which
        # rule a cell breaks.
        findings.extend(_include_findings(ctx, rel, [it for it in items if it.name == "include" and it.kind == "block"]))
        terraform_blocks = [it for it in items if it.name == "terraform" and it.kind == "block"]
        if terraform_blocks:
            first = terraform_blocks[0]
            value = _cells.attributes(first.tokens).get("source")
            if not isinstance(value, str):
                findings.append(Finding(check, "missing-source", rel, first.line, "terraform block must set source to a string path under stacks/"))
            else:
                source = _cells.unquote(value)
                cell_dir = (ctx.root / rel).parent
                if "${" in source:
                    findings.append(Finding(check, "source-not-static", rel, first.line, "source must be a literal relative path, not a template"))
                else:
                    resolved = _cells.resolve_under_root(cell_dir, source, ctx.root)
                    if not resolved or not resolved.startswith("stacks/"):
                        findings.append(Finding(check, "source-not-under-stacks", rel, first.line, f"source resolves to {resolved or 'outside the repository'}; a cell calls a stack under stacks/ (README, Three layers)"))
                    elif not (ctx.root / resolved).is_dir():
                        findings.append(Finding(check, "source-missing", rel, first.line, f"source resolves to {resolved}, which does not exist"))
        # A dependencies block orders this cell after other cells. Each path
        # must resolve to a cell (a directory under tenants/ holding a
        # terragrunt.hcl): Terragrunt would fail on a missing one at run time,
        # and cells.py silently drops a path it cannot resolve, so a cell moved
        # one level down leaves its dependents pointing at nothing unless this
        # says so.
        dependency_blocks = [it for it in items if it.name == "dependencies" and it.kind == "block"]
        if dependency_blocks:
            first = dependency_blocks[0]
            value = _cells.attributes(first.tokens).get("paths")
            if not isinstance(value, list):
                findings.append(Finding(check, "dependencies-paths-missing", rel, first.line, "dependencies must set paths to a list of literal relative cell paths"))
            else:
                cell_dir = (ctx.root / rel).parent
                for entry in value:
                    if not isinstance(entry, str) or "${" in entry:
                        findings.append(Finding(check, "dependency-not-static", rel, first.line, "each dependencies path must be a literal relative path, not a template"))
                        continue
                    dependency = _cells.unquote(entry)
                    resolved = _cells.resolve_under_root(cell_dir, dependency, ctx.root)
                    if not resolved or not resolved.startswith("tenants/"):
                        findings.append(Finding(check, "dependency-outside-tenants", rel, first.line, f"dependency {dependency} resolves to {resolved or 'outside the repository'}; a cell depends on another cell under tenants/"))
                    elif not (ctx.root / resolved / "terragrunt.hcl").is_file():
                        findings.append(Finding(check, "dependency-missing", rel, first.line, f"dependency {dependency} resolves to {resolved}, which is not a cell (no terragrunt.hcl there); a cell moved one level down leaves its dependents' paths one level short"))
    return findings


# ---------------------------------------------------------------------------
# fragment-shape
# ---------------------------------------------------------------------------


def cell_dirs(files: Iterable[str]) -> set[str]:
    """The directories under tenants/ that hold a terragrunt.hcl, from a file list."""
    return {rel[: -len("/terragrunt.hcl")] for rel in files if rel.startswith("tenants/") and rel.endswith("/terragrunt.hcl")}


def _included_fragments(ctx: Context, cell_rel: str) -> set[str] | None:
    """The bare file names a cell's include blocks name, or None when the cell cannot be read."""
    try:
        items = _cells.parse_items(_cells.tokenize(ctx.read_text(cell_rel)))
    except _cells.HclSyntaxError:
        return None
    names: set[str] = set()
    for it in items:
        if it.name == "include" and it.kind == "block":
            value = _cells.attributes(it.tokens).get("path")
            if isinstance(value, str):
                names.add(_cells.unquote(value))
    return names


def check_fragment_shape(ctx: Context) -> list[Finding]:
    """fragment-shape: a fragment is values only, like the cell it belongs to: every .hcl file beside a cell's terragrunt.hcl holds one inputs attribute and nothing else, and the cell includes it (README "Three layers"; ADR 0002)."""
    findings: list[Finding] = []
    check = "fragment-shape"
    dirs = cell_dirs(ctx.files)
    included: dict[str, set[str] | None] = {}
    for rel in ctx.text_files():
        directory, _, name = rel.rpartition("/")
        if directory not in dirs or name == "terragrunt.hcl" or not name.endswith(".hcl"):
            continue
        try:
            items = _cells.parse_items(_cells.tokenize(ctx.read_text(rel)))
        except _cells.HclSyntaxError as exc:
            findings.append(Finding(check, "fragment-parse-error", rel, None, f"cannot read as HCL: {exc}"))
            continue
        inputs = 0
        for it in items:
            if it.name == "inputs" and it.kind == "attribute":
                inputs += 1
                if inputs == 2:
                    findings.append(Finding(check, "fragment-forbidden-block", rel, it.line, "inputs appears more than once; a fragment holds exactly one inputs attribute"))
            elif it.name == "inputs":
                findings.append(Finding(check, "fragment-forbidden-block", rel, it.line, "inputs must be an attribute (inputs = { ... }), not a block"))
            elif it.name in _CELL_FORBIDDEN:
                findings.append(Finding(check, "fragment-forbidden-block", rel, it.line, f"{it.name}: {_CELL_FORBIDDEN[it.name]}; a fragment is values only, like the cell it belongs to"))
            else:
                findings.append(Finding(check, "fragment-forbidden-block", rel, it.line, f"{it.name}: a fragment holds one inputs attribute and nothing else, not an include, a source, a dependency, or a generate; those belong to the cell's terragrunt.hcl (ADR 0002)"))
        if inputs == 0:
            findings.append(Finding(check, "fragment-missing-inputs", rel, None, "a fragment holds one inputs attribute (inputs = { <one map> = { ... } }); a file with nothing to merge is not a fragment"))
        if directory not in included:
            included[directory] = _included_fragments(ctx, f"{directory}/terragrunt.hcl")
        names = included[directory]
        if names is not None and name not in names:
            findings.append(Finding(check, "fragment-not-included", rel, None, f"no include of {directory}/terragrunt.hcl names {name}; a fragment Terragrunt never merges is dead values, so include it (include \"<label>\" {{ path = \"{name}\" }}) or remove it"))
    return findings


# ---------------------------------------------------------------------------
# locators
# ---------------------------------------------------------------------------

_PARTITION_PLACE = re.compile(r"^tenants/aws/([^/]+)/partition\.hcl$")
_ACCOUNT_PLACE = re.compile(r"^tenants/aws/([^/]+)/accounts/([^/]+)/account\.hcl$")
_SUBSCRIPTION_PLACE = re.compile(r"^tenants/azure/([^/]+)/subscriptions/([^/]+)/subscription\.hcl$")
_REGION_RE = re.compile(r"^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$")
_LOWER_GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_ACCOUNT_RE = re.compile(r"^[0-9]{12}$")


def _locator_locals(ctx: Context, rel: str, findings: list[Finding]) -> dict[str, str] | None:
    """The string locals of a locator, or None after recording why it could not be read."""
    check = "locators"
    try:
        items = _cells.parse_items(_cells.tokenize(ctx.read_text(rel)))
    except _cells.HclSyntaxError as exc:
        findings.append(Finding(check, "locator-parse-error", rel, None, f"cannot read as HCL: {exc}"))
        return None
    locals_blocks = [it for it in items if it.name == "locals" and it.kind == "block"]
    for it in items:
        if it.name != "locals":
            findings.append(Finding(check, "locator-extra-block", rel, it.line, f"{it.name}: a locator holds one locals block and nothing else; it is not a cell (ADR 0017)"))
    if not locals_blocks:
        findings.append(Finding(check, "locator-no-locals", rel, None, "a locator must hold a locals block (ADR 0017)"))
        return None
    values: dict[str, str] = {}
    for it in locals_blocks:
        for name, value in _cells.attributes(it.tokens).items():
            if isinstance(value, str):
                values[name] = _cells.unquote(value)
            else:
                findings.append(Finding(check, "locator-value-not-literal", rel, it.line, f"{name} must be a quoted literal; a locator is an address, not a computation (ADR 0017)"))
    return values


def check_locators(ctx: Context) -> list[Finding]:
    """locators: partition.hcl, account.hcl, and subscription.hcl are locals-only addresses that sit where the layout puts them and say what the roots check (ADR 0017; README "Three kinds of stack")."""
    findings: list[Finding] = []
    check = "locators"
    for rel in ctx.text_files():
        name = rel.rsplit("/", 1)[-1]
        if name not in _cells.LOCATOR_NAMES:
            continue
        if name == "partition.hcl":
            placed = _PARTITION_PLACE.match(rel)
        elif name == "account.hcl":
            placed = _ACCOUNT_PLACE.match(rel)
        else:
            placed = _SUBSCRIPTION_PLACE.match(rel)
        if not placed:
            findings.append(Finding(check, "locator-misplaced", rel, None, f"{name} belongs at the level ADR 0017 gives it, not here"))
            continue
        values = _locator_locals(ctx, rel, findings)
        if values is None:
            continue
        if name == "partition.hcl":
            partition = values.get("partition", "")
            region = values.get("region", "")
            if partition not in ("aws", "aws-us-gov"):
                findings.append(Finding(check, "partition-invalid", rel, None, "partition must be the ARN partition, aws or aws-us-gov (ADR 0017)"))
            if not region:
                findings.append(Finding(check, "partition-region-missing", rel, None, "partition.hcl must set region, the default region of its account cells (ADR 0017)"))
            elif not _REGION_RE.match(region):
                findings.append(Finding(check, "partition-region-invalid", rel, None, f"region {region!r} is not an AWS region name"))
            elif partition in ("aws", "aws-us-gov") and (partition == "aws-us-gov") != region.startswith("us-gov-"):
                findings.append(Finding(check, "partition-region-mismatch", rel, None, f"region {region} is not in partition {partition}"))
        elif name == "account.hcl":
            account_id = values.get("account_id", "")
            account_name = values.get("account_name", "")
            directory = placed.group(2)
            if not _ACCOUNT_RE.match(account_id):
                findings.append(Finding(check, "account-id-invalid", rel, None, "account_id must be exactly 12 digits (tenants/aws/root.hcl refuses anything else)"))
            if account_name != directory:
                findings.append(Finding(check, "account-name-mismatch", rel, None, f"account_name {account_name!r} must equal the directory name {directory!r} (ADR 0017)"))
        else:
            sub_id = values.get("subscription_id", "")
            sub_name = values.get("subscription_name", "")
            directory = placed.group(2)
            if not _LOWER_GUID_RE.match(sub_id):
                findings.append(Finding(check, "subscription-id-invalid", rel, None, "subscription_id must be a lower-case GUID (tenants/azure/root.hcl refuses anything else)"))
            if sub_name != directory:
                findings.append(Finding(check, "subscription-name-mismatch", rel, None, f"subscription_name {sub_name!r} must equal the directory name {directory!r} (ADR 0017)"))
    findings.extend(_missing_locators(ctx))
    return findings


def _subdirs(path: Path) -> list[Path]:
    if not path.is_dir():
        return []
    return sorted(p for p in path.iterdir() if p.is_dir() and not p.name.startswith(".") and p.name not in SKIP_DIR_NAMES)


def _missing_locators(ctx: Context) -> list[Finding]:
    """A partition, account, or subscription directory with no locator addresses its cells by accident."""
    findings: list[Finding] = []
    check = "locators"
    for partition_dir in _subdirs(ctx.root / "tenants" / "aws"):
        rel = partition_dir.relative_to(ctx.root).as_posix()
        if not (partition_dir / "partition.hcl").is_file():
            findings.append(Finding(check, "locator-missing", f"{rel}/partition.hcl", None, "every partition directory carries partition.hcl (ADR 0017)"))
        for account_dir in _subdirs(partition_dir / "accounts"):
            arel = account_dir.relative_to(ctx.root).as_posix()
            if not (account_dir / "account.hcl").is_file():
                findings.append(Finding(check, "locator-missing", f"{arel}/account.hcl", None, "every accounts/<name>/ directory carries account.hcl; without it the cells beneath are addressed by ambient credentials (ADR 0017)"))
    for tenant_dir in _subdirs(ctx.root / "tenants" / "azure"):
        for sub_dir in _subdirs(tenant_dir / "subscriptions"):
            srel = sub_dir.relative_to(ctx.root).as_posix()
            if not (sub_dir / "subscription.hcl").is_file():
                findings.append(Finding(check, "locator-missing", f"{srel}/subscription.hcl", None, "every subscriptions/<name>/ directory carries subscription.hcl; without it the cells beneath fall back to ARM_SUBSCRIPTION_ID (ADR 0017)"))
    return findings


# ---------------------------------------------------------------------------
# placeholders
# ---------------------------------------------------------------------------


def load_builtin_ids(path: Path = BUILTIN_IDS_FILE) -> dict[str, str]:
    """Read the allowlist of published Microsoft ids; malformed lines are an input error."""
    ids: dict[str, str] = {}
    if not path.is_file():
        return ids
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        guid, _, description = line.partition(" ")
        if not _LOWER_GUID_RE.match(guid):
            raise ValueError(f"{path}:{lineno}: {guid!r} is not a lower-case GUID")
        ids[guid] = description.strip()
    return ids


def _is_placeholder_guid(guid: str) -> bool:
    return len(set(guid.lower().replace("-", ""))) == 1


def _domain_allowed(host: str, allowed: Sequence[str] = ALLOWED_DOMAINS) -> bool:
    host = host.lower()
    return any(host == d or host.endswith("." + d) for d in allowed)


def check_placeholders(ctx: Context) -> list[Finding]:
    """placeholders: every name and id in the tree is a placeholder (README: "Every name, CIDR, and ID in it is a placeholder")."""
    findings: list[Finding] = []
    check = "placeholders"
    builtin = load_builtin_ids()
    for rel in ctx.text_files():
        for lineno, line in enumerate(ctx.read_text(rel).splitlines(), start=1):
            for m in _GUID_RE.finditer(line):
                guid = m.group(1)
                if _is_placeholder_guid(guid) or guid.lower() in builtin:
                    continue
                findings.append(Finding(check, "guid-not-placeholder", rel, lineno, f"{guid} is not a repeated-digit GUID, all zeros, or a published Microsoft id (add it to microsoft_builtin_ids.txt if it is one)"))
            without_guids = _GUID_RE.sub(lambda mm: " " * len(mm.group(0)), line)
            for m in _ACCOUNT_ID_RE.finditer(without_guids):
                digits = m.group(1)
                if len(set(digits)) != 1:
                    findings.append(Finding(check, "account-id-not-placeholder", rel, lineno, f"{digits} looks like an account id and is not one repeated digit"))
            for m in _EMAIL_RE.finditer(line):
                if not _domain_allowed(m.group(2), PLACEHOLDER_DOMAINS):
                    findings.append(Finding(check, "email-not-placeholder", rel, lineno, f"email address at @{m.group(2)} is outside the documentation domains ({', '.join(PLACEHOLDER_DOMAINS)})"))
            for m in _HOST_RE.finditer(line):
                host = m.group(1)
                if host.split(".", 1)[0] in _REFERENCE_ROOTS:
                    continue
                if not _domain_allowed(host):
                    findings.append(Finding(check, "hostname-not-placeholder", rel, lineno, f"{host} looks like a real hostname; use a documentation domain or a vendor endpoint"))
    return findings


# ---------------------------------------------------------------------------
# ascii
# ---------------------------------------------------------------------------

_ASCII_LIMIT_PER_FILE = 25


def check_ascii(ctx: Context) -> list[Finding]:
    """ascii: every text file is plain ASCII, so no dash, quote, or space depends on an encoding in a review diff or in a runbook on Windows PowerShell 5.1 (repository convention; .editorconfig, ADR 0010)."""
    findings: list[Finding] = []
    check = "ascii"
    for rel in ctx.files:
        data = ctx.read_bytes(rel)
        if data.isascii() or ctx.is_binary(rel):
            continue
        reported = 0
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            for lineno, raw in enumerate(data.split(b"\n"), start=1):
                for col, byte in enumerate(raw, start=1):
                    if byte < 0x80:
                        continue
                    if reported < _ASCII_LIMIT_PER_FILE:
                        findings.append(Finding(check, "invalid-utf8", rel, lineno, f"column {col}: byte 0x{byte:02X} is not ASCII and the file is not valid UTF-8"))
                    reported += 1
        else:
            for lineno, raw in enumerate(text.split("\n"), start=1):
                for col, ch in enumerate(raw, start=1):
                    cp = ord(ch)
                    if cp < 0x80:
                        continue
                    if reported < _ASCII_LIMIT_PER_FILE:
                        findings.append(Finding(check, *_ascii_code(cp), rel, lineno, f"column {col}: {_ascii_message(cp)}"))
                    reported += 1
        if reported > _ASCII_LIMIT_PER_FILE:
            findings.append(Finding(check, "non-ascii", rel, None, f"and {reported - _ASCII_LIMIT_PER_FILE} more non-ASCII character(s)"))
    return findings


def _ascii_code(cp: int) -> tuple[str]:
    if cp == 0x2014:
        return ("em-dash",)
    if cp == 0x2013:
        return ("en-dash",)
    if cp == 0xFEFF:
        return ("utf8-bom",)
    return ("non-ascii",)


def _ascii_message(cp: int) -> str:
    if cp == 0x2014:
        return "em dash (U+2014); write a comma, a colon, a semicolon, or parentheses instead"
    if cp == 0x2013:
        return "en dash (U+2013); write 'to' or a hyphen instead"
    if cp == 0xFEFF:
        return "UTF-8 byte order mark (U+FEFF); save the file without a BOM"
    return f"non-ASCII character U+{cp:04X}"


# ---------------------------------------------------------------------------
# no-secrets
# ---------------------------------------------------------------------------


def _looks_placeholder(value: str) -> bool:
    return bool(_PLACEHOLDER_VALUE_RE.search(value)) or len(set(value)) == 1


def _is_literal_value(value: str, bare: bool) -> bool:
    """True when an assigned value is a literal worth reporting.

    Not a reference, a URL, a path, a run-time expansion, or a placeholder;
    for a bare value not a cmdlet, an identifier, or a word; for a quoted one
    not an environment variable's name.
    """
    if _NOT_A_LITERAL_RE.match(value) or _EXPANSION_RE.search(value) or _looks_placeholder(value):
        return False
    if bare:
        return not _BARE_CODE_RE.match(value)
    return not _QUOTED_NAME_RE.match(value)


def check_no_secrets(ctx: Context) -> list[Finding]:
    """no-secrets: nothing in the tree is a credential; the one credential by nature reaches Terraform through the environment and appears in no file (ADR 0003)."""
    findings: list[Finding] = []
    check = "no-secrets"
    for rel in ctx.text_files():
        heuristic = not _is_test_path(rel)
        for lineno, line in enumerate(ctx.read_text(rel).splitlines(), start=1):
            for code, pattern, label in _SECRET_PATTERNS:
                for m in pattern.finditer(line):
                    if _looks_placeholder(m.group(0)):
                        continue
                    findings.append(Finding(check, code, rel, lineno, f"{label} pattern; move it to an environment secret and reference it by name"))
            if not heuristic:
                continue
            for m in _SECRET_ASSIGN_RE.finditer(line):
                bare = m.group("value") is None
                value = m.group("bare") if bare else m.group("value")
                if not _is_literal_value(value, bare):
                    continue
                how = "a bare literal of 12 or more characters" if bare else "a quoted literal longer than 6 characters"
                findings.append(Finding(check, "literal-secret-assignment", rel, lineno, f"{m.group('name')} is assigned {how}; use CHANGEME or an environment reference"))
    return findings


# ---------------------------------------------------------------------------
# readme-tables
# ---------------------------------------------------------------------------


def _tf_dirs(base: Path, root: Path) -> list[str]:
    """Directories under base that hold a .tf file: each is a module or a stack."""
    found: list[str] = []
    if not base.is_dir():
        return found
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIR_NAMES and not d.startswith("."))
        if any(f.endswith(".tf") for f in filenames):
            found.append(Path(dirpath).relative_to(root).as_posix())
    return sorted(found)


def layout_paths(readme: str) -> list[tuple[str, int]]:
    """Paths named by the README Layout tree, with their line numbers.

    The tree is the first fenced block after the ``## Layout`` heading. Each
    line's first word is a path segment at a depth given by two-space
    indentation; a line indented deeper than one level below its parent is
    the continuation of a description, not a path.
    """
    lines = readme.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(r"^##\s+Layout\b", l)), None)
    if start is None:
        return []
    i = start + 1
    while i < len(lines) and not lines[i].startswith("```"):
        if lines[i].startswith("## "):
            return []
        i += 1
    if i >= len(lines):
        return []
    paths: list[tuple[str, int]] = []
    stack: list[str] = []
    for lineno in range(i + 1, len(lines)):
        line = lines[lineno]
        if line.startswith("```"):
            break
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        depth = indent // 2
        token = line.strip().split()[0]
        if depth == 0:
            stack = [""]
            continue
        if depth > len(stack):
            continue
        stack = stack[:depth] + [token]
        paths.append(("".join(stack[1:]).rstrip("/"), lineno + 1))
    return paths


def check_readme_tables(ctx: Context) -> list[Finding]:
    """readme-tables: README.md names every module and stack directory and its Layout tree names only paths that exist (README "What it manages" and "Layout")."""
    findings: list[Finding] = []
    check = "readme-tables"
    readme_rel = "README.md"
    if not (ctx.root / readme_rel).is_file():
        return [Finding(check, "readme-missing", readme_rel, None, "README.md is missing")]
    readme = ctx.read_text(readme_rel)
    for module in _tf_dirs(ctx.root / "modules", ctx.root):
        if not re.search(re.escape(module) + r"(?![A-Za-z0-9_\-])", readme):
            findings.append(Finding(check, "module-not-in-readme", module, None, f"{module} is not named in README.md (What it manages)"))
    for stack in _tf_dirs(ctx.root / "stacks", ctx.root):
        if not re.search(re.escape(stack) + r"(?![A-Za-z0-9_\-])", readme):
            findings.append(Finding(check, "stack-not-in-readme", stack, None, f"{stack} is not named in README.md (the stack tables)"))
    paths = layout_paths(readme)
    if not paths:
        findings.append(Finding(check, "layout-block-missing", readme_rel, None, "README.md has no Layout tree under a '## Layout' heading"))
    for path, lineno in paths:
        if path and not (ctx.root / path).exists():
            findings.append(Finding(check, "layout-path-missing", readme_rel, lineno, f"Layout names {path}, which does not exist"))
    return findings


# ---------------------------------------------------------------------------
# runbook-params
# ---------------------------------------------------------------------------


def blank_powershell(text: str) -> str:
    """Replace comments and string contents with spaces, keeping every newline.

    Line numbers and offsets are preserved, so a match in the result points
    at the same place in the source. Handles <# #> blocks, # lines, single-
    and double-quoted strings with their doubled-quote escapes, backtick
    escapes, $( ) subexpressions inside double-quoted strings, and both
    here-string forms.
    """
    out: list[str] = []
    i = 0
    n = len(text)

    def blank(segment: str) -> str:
        return "".join("\n" if c == "\n" else " " for c in segment)

    def read_quoted(start: int, quote: str) -> int:
        j = start + 1
        while j < n:
            c = text[j]
            if quote == '"' and c == "`":
                j += 2
                continue
            if quote == '"' and c == "$" and text.startswith("$(", j):
                j = read_subexpression(j + 1)
                continue
            if c == quote:
                if text.startswith(quote * 2, j):
                    j += 2
                    continue
                return j + 1
            j += 1
        return n

    def read_subexpression(start: int) -> int:
        depth = 0
        j = start
        while j < n:
            c = text[j]
            if c in "'\"":
                j = read_quoted(j, c)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return n

    while i < n:
        c = text[i]
        if text.startswith("<#", i):
            j = text.find("#>", i + 2)
            j = n if j < 0 else j + 2
            out.append(blank(text[i:j]))
            i = j
            continue
        if c == "#":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(blank(text[i:j]))
            i = j
            continue
        if c == "@" and i + 1 < n and text[i + 1] in "'\"":
            quote = text[i + 1]
            terminator = "\n" + quote + "@"
            j = text.find(terminator, i + 2)
            j = n if j < 0 else j + len(terminator)
            out.append(blank(text[i:j]))
            i = j
            continue
        if c in "'\"":
            j = read_quoted(i, c)
            out.append(c + blank(text[i + 1 : j - 1]) + (text[j - 1] if j - 1 > i else ""))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


_PARAM_RE = re.compile(r"(?<![\w-])param\s*\(", re.IGNORECASE)
_SWITCH_RE = re.compile(r"\[\s*switch\s*\]\s*(\$\w+)?", re.IGNORECASE)
_ARRAY_RE = re.compile(r"\[\s*([A-Za-z0-9_.]+)\s*\[\s*\]\s*\]\s*(\$\w+)?")
_WRITE_HOST_RE = re.compile(r"(?<![\w-])Write-Host(?![\w-])", re.IGNORECASE)


def top_level_param_block(blanked: str) -> tuple[int, int] | None:
    """Offsets of the first param( ... ) that sits outside every brace, or None."""
    depth = 0
    i = 0
    n = len(blanked)
    while i < n:
        c = blanked[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif depth == 0 and c in "pP":
            m = _PARAM_RE.match(blanked, i)
            if m:
                start = m.end() - 1
                level = 0
                for j in range(start, n):
                    if blanked[j] == "(":
                        level += 1
                    elif blanked[j] == ")":
                        level -= 1
                        if level == 0:
                            return (start, j + 1)
                return (start, n)
        i += 1
    return None


def check_runbook_params(ctx: Context) -> list[Finding]:
    """runbook-params: a job schedule can only bind strings, numbers, and booleans, so a runbook's top-level parameters are never [switch] or arrays (lists arrive as semicolon strings), and output goes to the job stream, never Write-Host (README "Verification status"; ADR 0010)."""
    findings: list[Finding] = []
    check = "runbook-params"
    for rel in ctx.text_files():
        if not (rel.startswith("automation/runbooks/") and rel.lower().endswith(".ps1")):
            continue
        blanked = blank_powershell(ctx.read_text(rel))
        span = top_level_param_block(blanked)
        if span:
            block = blanked[span[0] : span[1]]
            for m in _SWITCH_RE.finditer(block):
                name = m.group(1) or "(unnamed)"
                findings.append(Finding(check, "switch-parameter", rel, _line_of(blanked, span[0] + m.start()), f"{name} is [switch]; a job schedule cannot bind a switch, declare [bool] with a default"))
            for m in _ARRAY_RE.finditer(block):
                name = m.group(2) or "(unnamed)"
                findings.append(Finding(check, "array-parameter", rel, _line_of(blanked, span[0] + m.start()), f"{name} is [{m.group(1)}[]]; a job schedule cannot bind an array, take a semicolon-separated string and split it"))
        for m in _WRITE_HOST_RE.finditer(blanked):
            findings.append(Finding(check, "write-host", rel, _line_of(blanked, m.start()), "Write-Host writes to the host, not the job stream; use Write-Output or Write-Verbose"))
    return findings


# ---------------------------------------------------------------------------
# adr-index
# ---------------------------------------------------------------------------

_ADR_FILE_RE = re.compile(r"^(\d{4})-.+\.md$")
_ADR_TITLE_RE = re.compile(r"^#\s+ADR\s+(\d{4})\b")
_STATUS_RE = re.compile(r"^Status:\s*\S")
_DATE_RE = re.compile(r"^Date:\s*\d{4}-\d{2}-\d{2}\s*$")


def check_adr_index(ctx: Context) -> list[Finding]:
    """adr-index: the decision records carry the reasoning the commits do not, so each has a Status and a Date and the numbers form an unbroken index (README "History")."""
    findings: list[Finding] = []
    check = "adr-index"
    adr_dir = ctx.root / "docs" / "adr"
    if not adr_dir.is_dir():
        return [Finding(check, "adr-dir-missing", "docs/adr", None, "docs/adr is missing")]
    numbers: dict[int, list[str]] = {}
    for rel in ctx.text_files():
        if not rel.startswith("docs/adr/"):
            continue
        name = rel.rsplit("/", 1)[-1]
        m = _ADR_FILE_RE.match(name)
        if not m:
            continue
        number = int(m.group(1))
        numbers.setdefault(number, []).append(rel)
        head = ctx.read_text(rel).splitlines()[:30]
        if not any(_STATUS_RE.match(l) for l in head):
            findings.append(Finding(check, "status-missing", rel, None, "no 'Status: ...' line in the first 30 lines"))
        if not any(_DATE_RE.match(l) for l in head):
            findings.append(Finding(check, "date-missing", rel, None, "no 'Date: YYYY-MM-DD' line in the first 30 lines"))
        title = next((_ADR_TITLE_RE.match(l) for l in head if _ADR_TITLE_RE.match(l)), None)
        if title and int(title.group(1)) != number:
            findings.append(Finding(check, "title-number-mismatch", rel, 1, f"title says ADR {title.group(1)} but the file is numbered {m.group(1)}"))
    if numbers:
        ordered = sorted(numbers)
        if ordered[0] != 1:
            findings.append(Finding(check, "first-not-0001", "docs/adr", None, f"the first ADR is {ordered[0]:04d}; the index starts at 0001"))
        for number, files in numbers.items():
            if len(files) > 1:
                findings.append(Finding(check, "number-duplicate", "docs/adr", None, f"ADR {number:04d} is used by {', '.join(sorted(files))}"))
        for prev, nxt in zip(ordered, ordered[1:]):
            if nxt != prev + 1:
                findings.append(Finding(check, "number-gap", "docs/adr", None, f"ADR {prev + 1:04d} is missing between {prev:04d} and {nxt:04d}"))
    return findings


# ---------------------------------------------------------------------------
# Registry and runner.
# ---------------------------------------------------------------------------

CHECKS: dict[str, CheckFn] = {
    "cell-shape": check_cell_shape,
    "fragment-shape": check_fragment_shape,
    "locators": check_locators,
    "placeholders": check_placeholders,
    "ascii": check_ascii,
    "no-secrets": check_no_secrets,
    "readme-tables": check_readme_tables,
    "runbook-params": check_runbook_params,
    "adr-index": check_adr_index,
}


def check_rationale(name: str) -> str:
    """The first line of a check's docstring: what it enforces and where the rule is written."""
    doc = CHECKS[name].__doc__ or ""
    return doc.strip().splitlines()[0]


@dataclass
class Report:
    """What a run produced: which checks ran, over how many files, with what findings."""

    root: str
    checks: list[str]
    files_scanned: int
    findings: list[Finding]

    @property
    def ok(self) -> bool:
        return not self.findings

    def to_dict(self) -> dict:
        by_check: dict[str, int] = {name: 0 for name in self.checks}
        for f in self.findings:
            by_check[f.check] = by_check.get(f.check, 0) + 1
        return {
            "root": self.root,
            "checks": self.checks,
            "files_scanned": self.files_scanned,
            "ok": self.ok,
            "findings": [f.to_dict() for f in self.findings],
            "summary": {"findings": len(self.findings), "by_check": by_check},
        }


def select_checks(only: Iterable[str] | None, skip: Iterable[str] | None) -> list[str]:
    """Resolve --check and --skip into an ordered list; unknown names raise ValueError."""
    known = list(CHECKS)
    chosen = list(only) if only else list(known)
    for name in list(chosen) + list(skip or []):
        if name not in CHECKS:
            raise ValueError(f"unknown check {name!r}; known checks: {', '.join(known)}")
    skipped = set(skip or [])
    return [name for name in known if name in chosen and name not in skipped]


def run_checks(
    root: Path,
    names: Sequence[str] | None = None,
    files_mode: str = "auto",
    excludes: Sequence[str] = DEFAULT_EXCLUDES,
) -> Report:
    """Run the named checks (all by default) over root and collect their findings, sorted."""
    names = list(names) if names else list(CHECKS)
    ctx = Context(root=root, files=tracked_files(root, files_mode, excludes))
    findings: list[Finding] = []
    for name in names:
        findings.extend(CHECKS[name](ctx))
    findings.sort(key=lambda f: (names.index(f.check), f.path, f.line or 0, f.code))
    return Report(root=str(root), checks=names, files_scanned=len(ctx.files), findings=findings)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="repo_lint.py",
        description="Enforce the rules this repository writes down about itself.",
        epilog=(
            "Exit codes: 0 all selected checks passed; 1 findings; 2 usage or input error. "
            "Checks: " + ", ".join(CHECKS) + "."
        ),
    )
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    parser.add_argument("--check", action="append", metavar="NAME", help="run only this check; repeatable")
    parser.add_argument("--skip", action="append", metavar="NAME", help="skip this check; repeatable")
    parser.add_argument("--all", action="store_true", help="run every check (the default)")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--list-checks", action="store_true", help="list the checks with their rationale and exit")
    parser.add_argument(
        "--files",
        choices=("auto", "git", "walk"),
        default="auto",
        help="how to list files: git ls-files, a directory walk, or git when root is a repository (default)",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        metavar="PREFIX",
        default=None,
        help="root-relative path or directory prefix (ending in /) to leave out; repeatable; default excludes the fixture tree",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point; returns the exit code instead of calling sys.exit."""
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.list_checks:
        for name in CHECKS:
            print(f"{name:15} {check_rationale(name)}")
        return 0
    try:
        names = select_checks(args.check, args.skip)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2
    excludes = tuple(args.exclude) if args.exclude is not None else DEFAULT_EXCLUDES
    try:
        report = run_checks(root, names, args.files, excludes)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        for f in report.findings:
            print(f.format())
        if report.ok:
            print(f"repo_lint: {len(report.checks)} check(s) passed over {report.files_scanned} file(s)")
        else:
            print(f"repo_lint: {len(report.findings)} finding(s) over {report.files_scanned} file(s)")
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
