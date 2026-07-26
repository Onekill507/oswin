#!/usr/bin/env python3
"""Turn the guest's checklist beacon into a GitHub job-summary table."""
from __future__ import annotations

import argparse
import json
import os
import sys

ICON = {"ok": "&#9745;", "warn": "&#9888;", "fail": "&#9744;"}   # ☑ ⚠ ☐

# Order + friendly names for the items the task explicitly asked about.
PRIMARY = [
    "win11_25h2", "x64", "admin", "clean_install",
    "internet", "disk_space", "oobe", "backup",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    checklist = None
    with open(a.state, encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("stage") == "checklist" and rec.get("data"):
                checklist = rec["data"]

    if not checklist:
        print("::warning::No checklist beacon found.")
        return 0

    def row(key: str, item: dict) -> str:
        icon = ICON.get(item.get("level", "fail"), "&#9744;")
        label = item.get("label", key)
        detail = str(item.get("detail", "")).replace("|", "\\|")[:160]
        return f"| {icon} | {label} | `{detail}` |"

    lines = [
        "## AtlasOS readiness checklist",
        "",
        "Reported by the guest itself (`C:\\Atlas\\logs\\checklist.json`).",
        "",
        "### Required",
        "",
        "| | Requirement | Detail |",
        "|:-:|---|---|",
    ]
    for k in PRIMARY:
        if k in checklist:
            lines.append(row(k, checklist[k]))

    extra = [k for k in checklist if k not in PRIMARY]
    if extra:
        lines += ["", "### AME Wizard gates", "",
                  "| | Requirement | Detail |", "|:-:|---|---|"]
        lines += [row(k, checklist[k]) for k in extra]

    fails = [v["label"] for v in checklist.values() if v.get("level") == "fail"]
    warns = [v["label"] for v in checklist.values() if v.get("level") == "warn"]
    lines += ["", f"**{len(checklist)} checks - {len(fails)} failed, {len(warns)} warnings**"]
    if fails:
        lines.append("")
        lines.append("Failing: " + ", ".join(f"`{f}`" for f in fails))
    if warns:
        lines.append("")
        lines.append("Warnings (resolve inside the VM before running the playbook): "
                     + ", ".join(f"`{w}`" for w in warns))

    text = "\n".join(lines) + "\n"
    print(text)
    target = a.out or os.environ.get("GITHUB_STEP_SUMMARY", "")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(text)

    # Warnings are expected (Defender must be turned off by hand); only hard
    # failures of the eight required items break the build.
    hard = [k for k in PRIMARY
            if k in checklist and checklist[k].get("level") == "fail"]
    if hard:
        print(f"::error::Required checklist items failed: {', '.join(hard)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
