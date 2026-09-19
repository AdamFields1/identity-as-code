"""Put tools/ on sys.path so the tests import the gate as the package plan_gate.

The repository has no Python packaging and no pytest configuration, and the
tool must run as a file (python tools/plan_gate/plan_gate.py). This is the
one line of wiring that lets the tests import it the same way a caller with
tools/ on the path would.
"""

from __future__ import annotations

import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))
