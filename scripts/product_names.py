"""The former product names, as a pattern rather than a list of spellings.

Imported by `scripts/rename-to-latchkey.py` (renames the working tree) and
`scripts/history-scrub.py` (rewrites every commit). One definition, because two
copies of this rule is exactly the bug that made this module necessary.

WHY A PATTERN
-------------
A hand-written table of spellings failed twice over:

* **It was incomplete, and nothing said so.** The app's probe header was
  Title-Case-Hyphenated -- the shape HTTP headers are written in -- and that was
  the one shape the table lacked. It came through the rename, the history scrub
  and a passing `--check` untouched, still naming a trademark-encumbered product
  on the wire.

* **It could not survive its own scrub.** A table of old spellings is a file full
  of old spellings, so the history rewrite replaced both scripts' rules with
  `("Latchkey", "Latchkey")`. The rename tool's `--check` then read the NEW name
  as the forbidden one and flagged every correct file in the repository.

`kiro` is legitimate on its own -- KiroCrew contains it -- and `roam` and `nomad`
are ordinary words. Requiring them together, in that order, with an optional
separator, matches every spelling either product name ever had while putting no
forbidden spelling in any file. So there is nothing here for a scrub to corrupt,
and nothing needs an exemption from the checks.

NEVER match a bare `kiro`. `GatewayCandidates.manifestIsKiroCrew` recognises a
gateway by matching the literal `"Kiro Crew"` in its web-app manifest: corrupt
that and discovery finds nothing, on every tailnet, with no error at all.
"""

import re

NEW = "Latchkey"

# `kiro` + optional separator + `roam`/`nomad`, in any case: joined (Swift and Go
# identifiers), spaced (prose), hyphenated (the HTTP probe header, the old
# repository and directory names), underscored (the old build flag).
OLD_RE = re.compile(r"kiro[ _-]?(?:roam|nomad)", re.IGNORECASE)

# The same rule over bytes, for `scripts/history-verify.py`, which reads raw git
# blobs and must not guess their encoding. Derived from OLD_RE rather than
# written out twice -- a second copy is what this module exists to prevent.
OLD_RE_BYTES = re.compile(OLD_RE.pattern.encode(), re.IGNORECASE)

# The one former token with neither `roam` nor `nomad` in it, so the pattern
# cannot reach it. Safe as a literal: it names a whole token, and `KIRO` alone is
# never substituted. Assembled anyway, so this file stays free of old spellings.
LITERAL_SUBS = [("KIRO" + "_TEST_HOOKS", "LATCHKEY_TEST_HOOKS")]

# Masked before substitution and restored afterwards.
PRESERVE = [
    # The product this app is a client of: an official Kiro project, not ours,
    # and not being renamed. See the note at the top about the manifest literal.
    "KiroCrew", "Kiro Crew", "kirocrew", "kiro_crew", "KIROCREW", "KIRO_CREW",
    "kiro-crew",
    # Upstream's identity, inherited with the fork and not ours to rename.
    # `~/.aperture-ios-authkey` is a real path on the owner's machine and the two
    # APERTURE_* variables are read by upstream-shared code.
    "aperture-plus", "aperture-ios-authkey", "APERTURE_AUTHKEY",
    "APERTURE_EPHEMERAL", "tailscale/aperture",
]


def cased(match):
    """`Latchkey` in the case shape of whatever was matched.

    An ALL-CAPS match becomes `LATCHKEY` (the old build flag), an all-lowercase
    one `latchkey` (the old repository and directory names), and anything with a
    capital in it `Latchkey` -- which is what a Title-Case-Hyphenated HTTP header
    needs in order to come out as `X-Latchkey-Check`.
    """
    text = match.group(0)
    if text.isupper():
        return NEW.upper()
    if text.islower():
        return NEW.lower()
    return NEW


def rewrite(text):
    """Every former product spelling in `text` replaced, KiroCrew untouched.

    The PRESERVE masking is belt to the pattern's braces: `OLD_RE` cannot reach
    inside `kirocrew`, because `crew` is neither `roam` nor `nomad`. It is here so
    that loosening the pattern later cannot silently break discovery.
    """
    for i, keep in enumerate(PRESERVE):
        text = text.replace(keep, f"\x00P{i}\x00")
    text = OLD_RE.sub(cased, text)
    for old, new in LITERAL_SUBS:
        text = text.replace(old, new)
    for i, keep in enumerate(PRESERVE):
        text = text.replace(f"\x00P{i}\x00", keep)
    return text
