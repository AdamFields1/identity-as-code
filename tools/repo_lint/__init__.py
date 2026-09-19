"""repo_lint: the repository's written rules, enforced.

Two command-line tools live here. ``repo_lint.py`` checks the tree against
the rules the README and the decision records state (cell shape, locators,
placeholders, ASCII, secrets, README coverage, runbook parameters, ADR
index). ``cells.py`` discovers tenant cells, works out which ones a change
touches, and orders them into waves a release workflow can consume. Both
are standard-library Python with no runtime dependency; see README.md in
this folder for what each check enforces and where the rule comes from.
"""

__version__ = "0.1.0"
