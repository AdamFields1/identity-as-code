"""plan_gate: hold a Terraform plan JSON to a named profile.

The module ``plan_gate.plan_gate`` is both the CLI and the library; this
package file re-exports the library surface so ``from plan_gate import
evaluate`` works when ``tools/`` is on ``sys.path``. See ``plan_gate.py`` for
the contract and ``README.md`` for why the gate exists.
"""

from .plan_gate import (
    EXIT_FINDINGS,
    EXIT_PASS,
    EXIT_USAGE,
    PROFILES,
    Counts,
    Entry,
    Finding,
    GateOptions,
    Plan,
    PlanError,
    Result,
    __version__,
    classify_actions,
    compile_patterns,
    evaluate,
    format_markdown,
    format_summary,
    is_noise_only,
    load_allowlist,
    load_plan,
    main,
    normalize_value,
    parse_plan,
    results_to_dict,
    write_github_summary,
)

__all__ = [
    "EXIT_FINDINGS",
    "EXIT_PASS",
    "EXIT_USAGE",
    "PROFILES",
    "Counts",
    "Entry",
    "Finding",
    "GateOptions",
    "Plan",
    "PlanError",
    "Result",
    "__version__",
    "classify_actions",
    "compile_patterns",
    "evaluate",
    "format_markdown",
    "format_summary",
    "is_noise_only",
    "load_allowlist",
    "load_plan",
    "main",
    "normalize_value",
    "parse_plan",
    "results_to_dict",
    "write_github_summary",
]
