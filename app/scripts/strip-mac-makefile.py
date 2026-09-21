#!/usr/bin/env python3
"""Strip the macOS / virtualization / Thunderboot targets from the Makefile.

One-shot surgery for Latchkey milestone M1.1 / M1.2, kept alongside
strip-mac-targets.py for the same reason: a future `git merge upstream/main`
will re-add these, and a reviewer needs to see what was removed rather than
reverse-engineer it from a 500-line diff.

Line-based on purpose. The first version of this script used multi-line
regexes and silently emptied the file; a Makefile is a line-oriented format
and reads much more safely as one.

Run with --dry-run to see what would go without touching anything.
"""
from __future__ import annotations

import re
import sys

MAKEFILE = "Makefile"

MAC_TARGETS = {
    # macOS app and its UI tests (M1.1)
    "mac-framework", "mac-app", "mac-app-signed", "test-mac", "build-mac-uitests",
    "test-mac-ui",
    # Virtualization / Thunderboot appliance (M1.2)
    "aperture-vm-cli", "test-aperture-vm",
    "stage-thunderboot-development-artifacts", "stage-thunderboot-mac-app-artifacts",
    "import-thunderboot-appliance", "mac-artifacts",
    # App Store / TestFlight. PLAN §1.3 lists this as a non-goal: distribution
    # is personal sideloading only, and TailscaleKit's xcframework fails App
    # Store validation for a missing privacy manifest anyway (libtailscale
    # PR #57, open). Keeping the targets would only invite a 40-minute archive
    # that cannot be uploaded.
    "tf-mac-archive", "tf-mac-export", "tf-mac-validate", "tf-mac-upload", "tf-mac",
    "tf-check-creds", "tf-archive", "tf-export", "tf-validate", "tf-upload", "tf",
}

# Variable assignments only the removed targets used. Matched on the name to
# the left of the assignment operator.
DEAD_VARS = {
    "MAC_SCHEME", "MAC_DERIVED", "MAC_SIGNED_DERIVED", "MAC_APP_NAME",
    "MAC_FRAMEWORK", "MAC_ARCHIVE", "MAC_APPSTORE_DIR", "MAC_EXPORT_OPTS",
    "MAC_BUILD_OFFSET", "MAC_BUILD_NUMBER", "MAC_BUILD_NUM_FLAG", "MAC_GIT_COUNT",
    "THUNDERBOOT_SOURCE", "THUNDERBOOT_DEVELOPMENT_DIR", "THUNDERBOOT_MAC_APP_DIR",
    "IPA_APPSTORE_DIR", "EXPORT_OPTS_APPSTORE", "APERTURE_TF_ENV",
    "BUILD_NUMBER", "BUILD_NUM_FLAG",
}

# `ifndef X` / `ifeq (...)` blocks guarding a dead variable. Removed whole,
# tracking nesting, because half a conditional is a syntax error and an
# orphaned one silently evaluates to nonsense — the leftover
# `MAC_GIT_COUNT + MAC_BUILD_OFFSET` arithmetic made every `make` invocation
# print "/bin/sh: 201 + : syntax error".
DEAD_CONDITIONALS = (
    "ifndef MAC_BUILD_NUMBER",
    "ifndef BUILD_NUMBER",
    "ifneq ($(strip $(MAC_BUILD_NUMBER)),)",
    "ifneq ($(strip $(BUILD_NUMBER)),)",
)

# Makefile rules whose *target* is a dead variable reference, e.g.
# `$(MAC_FRAMEWORK): $(LIBTSCALE_SOURCES)`.
DEAD_RULE_HEADS = tuple("$(%s):" % v for v in DEAD_VARS)

PHONY_RE = re.compile(r"^\.PHONY:\s*(\S+)")
RULE_RE = re.compile(r"^([A-Za-z0-9_.$()/-]+):")
VAR_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*[:?+]?=")
SECTION_RE = re.compile(r"^# ----- ")


def is_block_start(line: str) -> bool:
    """True when `line` begins a new top-level Makefile construct, i.e. the
    point at which a removal must stop.

    A column-0 comment counts. Recipes are tab-indented, so a `#` in the first
    column after a rule is documentation for whatever comes next — without
    this, removing `MAC_FRAMEWORK :=` also ate the three-line comment
    explaining why `LIBTSCALE_SOURCES` exists, which has nothing to do with
    macOS.
    """
    return bool(
        line.startswith("#")
        or PHONY_RE.match(line)
        or SECTION_RE.match(line)
        or VAR_RE.match(line)
        or (RULE_RE.match(line) and not line.startswith("\t"))
        or line.startswith("ifndef ")
        or line.startswith("ifeq ")
        or line.startswith("ifneq ")
        or line.startswith(".DEFAULT_GOAL")
    )


def trailing_comment_block(out: list[str]) -> int:
    """Length of the comment block (plus one optional blank line) sitting at
    the end of `out`, so a target's own documentation goes with it."""
    i = len(out)
    if i and out[i - 1].strip() == "":
        return 0  # blank line: the comment above belongs to the section, not us
    while i > 0 and out[i - 1].startswith("#"):
        i -= 1
    return len(out) - i


def strip(text: str) -> tuple[str, list[str]]:
    lines = text.split("\n")
    out: list[str] = []
    removed: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith(DEAD_CONDITIONALS):
            for _ in range(trailing_comment_block(out)):
                removed.append(out.pop())
            depth = 0
            while i < len(lines):
                stripped_line = lines[i].strip()
                if stripped_line.startswith(("ifndef ", "ifdef ", "ifeq ", "ifneq ")):
                    depth += 1
                elif stripped_line == "endif":
                    depth -= 1
                removed.append(lines[i])
                i += 1
                if depth == 0:
                    break
            continue

        phony = PHONY_RE.match(line)
        rule = RULE_RE.match(line)
        var = VAR_RE.match(line)

        dead = (
            (phony and phony.group(1) in MAC_TARGETS)
            or (rule and rule.group(1) in MAC_TARGETS)
            or (var and var.group(1) in DEAD_VARS)
            or line.startswith(DEAD_RULE_HEADS)
        )
        if dead:
            # Take the target's own comment block with it.
            for _ in range(trailing_comment_block(out)):
                removed.append(out.pop())
            removed.append(line)
            i += 1
            # Consume the body: recipe lines, continuations and interior blank
            # lines, up to the next top-level construct.
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() == "":
                    # A blank line ends the block only if what follows is not
                    # part of it.
                    j = i + 1
                    while j < len(lines) and lines[j].strip() == "":
                        j += 1
                    if j >= len(lines) or is_block_start(lines[j]) or lines[j].startswith("#"):
                        break
                    removed.append(nxt)
                    i += 1
                    continue
                if is_block_start(nxt):
                    break
                removed.append(nxt)
                i += 1
            continue

        out.append(line)
        i += 1

    text = "\n".join(out)
    # Collapse blank-line runs the removals left behind.
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text, removed


def retarget(text: str) -> str:
    """Fix up the aggregate targets that still name removed ones."""
    text = text.replace(
        "test: test-policy test-ios-ui test-mac test-mac-ui  ## Run the complete required iOS + macOS suite",
        "test: test-policy test-ios-ui  ## Run the complete required iOS suite",
    )
    text = text.replace(
        "\trm -rf $(DERIVED) $(MAC_DERIVED) $(MAC_SIGNED_DERIVED) $(ARCHIVE) $(IPA_DIR) \\\n"
        "\t\t$(IPA_APPSTORE_DIR) $(MAC_ARCHIVE) $(MAC_APPSTORE_DIR)",
        "\trm -rf $(DERIVED) $(ARCHIVE) $(IPA_DIR) $(IPA_APPSTORE_DIR)",
    )
    text = text.replace(
        '\t@echo\n'
        '\t@echo "::: iOS build uploaded. For the NATIVE macOS app (ApertureMac), run: make tf-mac :::"\n'
        '\t@echo "::: (The iOS upload above does NOT include a native Mac build; it may still be :::"\n'
        '\t@echo ":::  installable on Apple-silicon Macs via \'Designed for iPad\' availability in :::"\n'
        '\t@echo ":::  App Store Connect — a separate, availability-switch concern.) :::"\n',
        "",
    )
    text = text.replace(
        "# The libtailscale build needs Go 1.26.5 and the iOS SDK; the app build needs\n"
        "# Xcode 26.x. Both are slow the first time.",
        "# The libtailscale build needs Go and the iOS SDK; the app build needs Xcode.\n"
        "# Latchkey builds both on Go 1.27.1 / Xcode 27 (docs/DECISIONS.md). Both are\n"
        "# slow the first time.",
    )
    return text


if __name__ == "__main__":
    original = open(MAKEFILE).read()
    stripped, removed = strip(original)
    stripped = retarget(stripped)

    before, after = len(original.split("\n")), len(stripped.split("\n"))
    print(f"{before} -> {after} lines ({len(removed)} removed)")
    # Sanity floor, not a ratio: removing the macOS, virtualization and
    # TestFlight targets legitimately takes about 60% of upstream's Makefile,
    # so a percentage guard would just cry wolf. What must never happen is the
    # file collapsing to nothing, which is exactly what the first (regex-based)
    # version of this script did.
    MINIMUM_LINES = 150
    if after < MINIMUM_LINES:
        sys.exit(f"refusing to write: only {after} lines would remain "
                 f"(expected at least {MINIMUM_LINES})")

    if "--dry-run" in sys.argv:
        for line in removed:
            print("  - " + line)
        sys.exit(0)

    open(MAKEFILE, "w").write(stripped)
    leftovers = [
        line.rstrip() for line in stripped.split("\n")
        if re.search(r"\bmac\b|Mac|thunderboot|Thunderboot|aperture-vm|virtualiz|MAC_", line, re.I)
    ]
    if leftovers:
        print("Remaining mentions (review by eye):")
        for line in leftovers:
            print("  " + line)
    print("ok")
