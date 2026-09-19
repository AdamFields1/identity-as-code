"""Shared fixtures: the two miniature trees and a way to copy one into tmp_path.

The good tree passes every check; the bad tree fails every check that can be
failed with files that are themselves ASCII and free of secret-looking
strings. The ascii and no-secrets failures are written into a copy of the
good tree at test time, so the repository never carries a non-ASCII byte or
a credential-shaped string, which is exactly what those two checks exist to
prevent.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pytest

TESTS_DIR = Path(__file__).resolve().parent
FIXTURES = TESTS_DIR / "fixtures"
TOOLS_DIR = TESTS_DIR.parent.parent

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))


@pytest.fixture(scope="session")
def good_root() -> Path:
    return FIXTURES / "good"


@pytest.fixture(scope="session")
def bad_root() -> Path:
    return FIXTURES / "bad"


@pytest.fixture
def good_copy(tmp_path: Path, good_root: Path) -> Path:
    """A writable copy of the good tree for tests that add a bad file to it."""
    target = tmp_path / "good"
    shutil.copytree(good_root, target)
    return target
