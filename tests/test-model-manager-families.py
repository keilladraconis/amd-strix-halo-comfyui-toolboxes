#!/usr/bin/env python3
# Unit tests for model_manager.py's workflow -> MODEL_FAMILIES matching.
# No dialog, no downloads: WORKFLOW_DIR is pointed at a temp directory of
# empty JSON files named after the bundled workflows.
import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

_spec = importlib.util.spec_from_file_location(
    "model_manager", ROOT / "scripts" / "model_manager.py"
)
model_manager = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(model_manager)

PASS = 0
FAIL = 0


def check(desc, expected, actual):
    global PASS, FAIL
    if expected == actual:
        PASS += 1
        print(f"ok: {desc}")
    else:
        FAIL += 1
        print(f"FAIL: {desc}")
        print(f"  expected: {expected}")
        print(f"  got     : {actual}")


def families_for(filenames):
    """Family names find_available_families() reports for a workflow
    directory containing exactly `filenames`."""
    with tempfile.TemporaryDirectory() as tmp:
        for name in filenames:
            (Path(tmp) / name).write_text("{}")
        model_manager.WORKFLOW_DIR = Path(tmp)
        return [family["name"] for family in model_manager.find_available_families()]


MINIMAX_WORKFLOWS = [
    "MiniMax-H3-T2V.json",
    "MiniMax-H3-I2V.json",
    "MiniMax-H3-R2V.json",
    "MiniMax-H3-Turbo-T2V.json",
    "MiniMax-H3-Turbo-I2V.json",
]

check(
    "all five MiniMax-H3 families are offered when all five workflows ship",
    [
        "MiniMax-H3 T2V",
        "MiniMax-H3 I2V",
        "MiniMax-H3 R2V",
        "MiniMax-H3 Turbo T2V",
        "MiniMax-H3 Turbo I2V",
    ],
    families_for(MINIMAX_WORKFLOWS),
)

check(
    "Turbo workflows alone do not activate the base T2V/I2V families",
    ["MiniMax-H3 Turbo T2V", "MiniMax-H3 Turbo I2V"],
    families_for(["MiniMax-H3-Turbo-T2V.json", "MiniMax-H3-Turbo-I2V.json"]),
)

check(
    "base workflows alone do not activate the Turbo families",
    ["MiniMax-H3 T2V", "MiniMax-H3 I2V", "MiniMax-H3 R2V"],
    families_for(["MiniMax-H3-T2V.json", "MiniMax-H3-I2V.json", "MiniMax-H3-R2V.json"]),
)

check(
    "every MiniMax-H3 family downloads via get_minimax_h3.sh",
    {"get_minimax_h3.sh"},
    {
        family["script"]
        for family in model_manager.MODEL_FAMILIES
        if family["name"].startswith("MiniMax-H3")
    },
)

# Ties the family data to the files actually committed in workflows/: a typo
# in either one shows up here rather than at runtime in the container.
bundled = [path.name for path in (ROOT / "workflows").glob("*.json")]
check(
    "the committed workflows/ directory activates all five MiniMax-H3 families",
    5,
    len([name for name in families_for(bundled) if name.startswith("MiniMax-H3")]),
)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
