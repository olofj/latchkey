#!/usr/bin/env python3
"""TestFlight "What to Test" notes for a Latchkey build (F26).

  tf_notes.py notes  [--purpose P] [--require-purpose] [--build N] [--out F]...
                     [--baseline COMMIT] [--check-asc]
      Print the notes for HEAD: why the build was sent, what shipped since
      the previous TestFlight build, and what to try.
  tf_notes.py set    --build N (--notes-file F | --from-tag) [--wait S] [--dry-run]
      Wait for App Store Connect to finish processing build N, then set its
      en-US whatToTest. --dry-run looks the build up and writes nothing.
  tf_notes.py latest
      Print the newest build App Store Connect has for the app (read-only).

The previous build is the newest tf/<build> tag that is an ancestor of HEAD,
or else the newest row of the Build history table in docs/TESTFLIGHT.md.
Standard library only; the JWT is signed by openssl. docs/features/F26-*.md
is the spec, and docs/TESTFLIGHT.md the usage.
"""
import argparse
import base64
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CAP = 4000           # App Store Connect's limit on whatToTest
PURPOSE_MAX = 500
LOCALE = "en-US"
DEFAULT_WAIT = 1800
POLL = 30
API_BASE = "https://api.appstoreconnect.apple.com"

# A commit ships if it touches one of these: what goes into the archive.
# Docs, UI tests, scripts and harnesses reach no tester.
SHIPPING = ("app/App/", "app/TSNet/", "app/ShareExtension/", "app/ThirdParty/",
            "app/Latchkey/", "app/Latchkey.xcodeproj/", "app/Latchkey.xcconfig")

TAG_PREFIX = "tf/"
HISTORY_HEADING = "## Build history"


class NotesError(Exception):
    """A refusal the user can act on; exit status 1."""


class ProcessingTimeout(Exception):
    """The build was still processing when the wait ran out; exit status 3."""


def units(text):
    """Length as App Store Connect may count it: UTF-16 code units, which is
    never less than the number of characters."""
    return len(text.encode("utf-16-le")) // 2


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


# ----- git -----

def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise NotesError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def is_ancestor(repo, commit, head):
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", commit, head],
                          capture_output=True).returncode == 0


def resolve(repo, rev):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", rev + "^{commit}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


# ----- the baseline -----

class Baseline:
    def __init__(self, sha, build=None, source=""):
        self.sha, self.build, self.source = sha, build, source

    @property
    def label(self):
        return f"build {self.build}" if self.build else f"commit {self.sha[:12]}"


def tag_candidates(repo, head):
    out = []
    for line in git(repo, "for-each-ref", "--format=%(refname:short)", "refs/tags/" + TAG_PREFIX).split():
        m = re.fullmatch(re.escape(TAG_PREFIX) + r"(\d+)", line)
        sha = m and resolve(repo, line)
        if sha and is_ancestor(repo, sha, head):
            out.append(Baseline(sha, int(m.group(1)), f"tag {line}"))
    return out


def history_rows(text):
    """(build, commit) rows of the Build history table: | 202610090504 | f72423742cba | ..."""
    rows, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = line.strip() == HISTORY_HEADING
            continue
        m = inside and re.match(r"\|\s*`?(\d{12})`?\s*\|\s*`?([0-9a-f]{7,40})`?\s*\|", line)
        if m:
            rows.append((int(m.group(1)), m.group(2)))
    return rows


def table_candidates(repo, head):
    path = os.path.join(repo, "docs", "TESTFLIGHT.md")
    if not os.path.exists(path):
        return []
    out = []
    for build, commit in history_rows(read_text(path)):
        sha = resolve(repo, commit)
        if sha and is_ancestor(repo, sha, head):
            out.append(Baseline(sha, build, "docs/TESTFLIGHT.md build history"))
    return out


def resolve_baseline(repo, head, below=None, override=None):
    if override:
        sha = resolve(repo, override)
        if not sha:
            raise NotesError(f"BASELINE={override} is not a commit here")
        return Baseline(sha, None, "BASELINE")
    cands = [c for c in tag_candidates(repo, head) + table_candidates(repo, head)
             if below is None or c.build < below]
    if not cands:
        raise NotesError(
            "no previous TestFlight build to start the notes from: no tf/<build> tag is an "
            "ancestor of HEAD, and docs/TESTFLIGHT.md's Build history has no row that is. "
            "Pass BASELINE=<commit of the last build> (docs/TESTFLIGHT.md).")
    # Newest build wins; at equal numbers a tag beats a table row.
    return max(cands, key=lambda c: (c.build, c.source.startswith("tag")))


# ----- specs -----

def spec_path(repo, fid):
    hits = sorted(glob.glob(os.path.join(repo, "docs", "features", fid + "-*.md")))
    return hits[0] if hits else None


def spec_title(text, fid):
    m = re.search(r"^\|\s*\*\*Testers\*\*\s*\|\s*(.+?)\s*\|\s*$", text, re.M)
    if m and not m.group(1).startswith("<"):        # TEMPLATE.md's placeholder
        return condense(m.group(1))
    m = re.search(r"^#\s+" + re.escape(fid) + r"\s*[—–:-]+\s*(.+?)\s*$", text, re.M)
    return condense(m.group(1)) if m else fid


def readme_issue_map(repo):
    """issue number -> feature id, from 'issue #k' in a README table row."""
    path = os.path.join(repo, "docs", "features", "README.md")
    out = {}
    if not os.path.exists(path):
        return out
    for line in read_text(path).splitlines():
        m = re.match(r"\|\s*\[(F\d+)\]", line)
        if m:
            for k in re.findall(r"\bissues? #(\d+)", line):
                out.setdefault(int(k), m.group(1))
    return out


def condense(text):
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)          # links keep their text
    t = re.sub(r"`([^`]*)`", r"\1", t)                          # code spans
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)                      # bold
    t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", t)  # italic
    t = re.sub(r"\s*\((?:see\s+)?§[\d.]+(?:\s*(?:,|and|–|-)\s*§?[\d.]+)*\)", "", t)  # (§5)
    return re.sub(r"\s+", " ", t).strip()


ITEM = re.compile(r"^(\s*)(?:\d+[.)]|[-*+])\s+(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")


def device_check_region(lines):
    for i, line in enumerate(lines):
        h = HEADING.match(line)
        if h and "device check" in h.group(2).lower():
            level, end = len(h.group(1)), len(lines)
            for j in range(i + 1, len(lines)):
                hj = HEADING.match(lines[j])
                if hj and len(hj.group(1)) <= level:
                    end = j
                    break
            return lines[i + 1:end]
        b = re.match(r"^(\s*)[-*+]\s+\*\*Device check", line, re.I)
        if b:
            indent, out = len(b.group(1)), []
            for nxt in lines[i + 1:]:
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
                    break
                out.append(nxt)
            return out
    return []


def device_checks(text):
    """The items of a spec's device check, condensed, without (owner only)."""
    region = device_check_region(text.splitlines())
    starts = [len(m.group(1)) for m in map(ITEM.match, region) if m]
    if not starts:
        return []
    base = min(starts)
    items, cur, blank = [], None, False
    for line in region:
        if not line.strip():
            blank = True
            continue
        m = ITEM.match(line)
        ind = len(line) - len(line.lstrip())
        if m and len(m.group(1)) == base:
            cur = [m.group(2)]
            items.append(cur)
        elif cur is not None and (ind > base or not blank):
            cur.append(line.strip())
        else:
            cur = None          # a paragraph after the list is not an item
        blank = False
    out = []
    for parts in items:
        t = condense(" ".join(parts))
        if re.search(r"\(owner only\)\.?$", t, re.I):
            continue
        if t:
            out.append(t)
    return out


# ----- commits -----

def commits(repo, base, head):
    """[(sha, subject, body, [paths])], oldest first."""
    out = []
    for sha in git(repo, "rev-list", "--reverse", f"{base}..{head}").split():
        msg = git(repo, "show", "-s", "--format=%B", sha)
        paths = git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "-m", "--root", sha).split("\n")
        subject, _, body = msg.partition("\n")
        out.append((sha, subject.strip(), body, [p for p in paths if p]))
    return out


def ships(paths):
    return any(p.startswith(SHIPPING) or p in SHIPPING for p in paths)


def drop_area(text):
    return re.sub(r"^[\w./+-]+:\s+", "", text.strip())


def gh_issue_title(repo, k):
    if os.environ.get("TF_NOTES_OFFLINE") == "1":
        return None
    try:
        r = subprocess.run(["gh", "issue", "view", str(k), "--json", "title", "-q", ".title"],
                           cwd=repo, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def classify(repo, base, head, issue_title=gh_issue_title):
    """-> (features {fid: spec text}, fixes [(k, line)], internal count)"""
    issue_to_feature = readme_issue_map(repo)
    features, fixes, internal = {}, {}, 0
    for sha, subject, body, paths in commits(repo, base, head):
        if not ships(paths):
            continue
        fids = re.findall(r"^Spec:\s*(?:\S*/)?(F\d+)-\S*\.md\s*$", body, re.M)
        issues = [int(k) for line in re.findall(r"^(?:Fixes|Closes):?\s+(.*)$", body, re.M | re.I)
                  for k in re.findall(r"#(\d+)", line)]
        fids += [issue_to_feature[k] for k in issues if k in issue_to_feature]
        hit = False
        for fid in fids:
            path = spec_path(repo, fid)
            if path:
                features[fid] = read_text(path)
                hit = True
        if hit:
            continue
        if issues:
            for k in issues:
                if k not in fixes:
                    title = issue_title(repo, k)
                    fixes[k] = drop_area(title) if title else drop_area(subject)
            continue
        internal += 1
    order = lambda fid: int(fid[1:])
    return ({f: features[f] for f in sorted(features, key=order)},
            [(k, fixes[k]) for k in sorted(fixes)], internal)


# ----- the notes -----

def check_purpose(purpose, required):
    p = re.sub(r"\s+", " ", purpose or "").strip()
    if not p:
        if required:
            raise NotesError(
                'no PURPOSE: say why this build goes to testers, e.g. '
                'make tf PURPOSE="Try the new mute button". It is the first line of '
                "TestFlight's What to Test (F26). UPLOAD=0 builds need none.")
        return "(no purpose given)"
    if len(p) > PURPOSE_MAX:
        raise NotesError(f"PURPOSE is {len(p)} characters; keep it under {PURPOSE_MAX}, "
                         "it is one line of the notes")
    return p


def render(purpose, since, changed, internal, blocks, sha, cut_changed=0, dropped_blocks=0):
    out = [f"Why this build: {purpose}", "", f"What changed since {since}:"]
    out += [f"- {line}" for line in changed]
    if cut_changed:
        out.append(f"- and {cut_changed} more")
    if internal:
        out.append(f"- Plus {internal} internal change{'s' if internal != 1 else ''} with nothing new to try."
                   if changed or cut_changed else
                   f"- No new features or fixes; {internal} internal change{'s' if internal != 1 else ''}.")
    if not changed and not cut_changed and not internal:
        out.append("- No changes to the app.")
    if blocks or dropped_blocks:
        out += ["", "Things to try:"]
        for header, items, omitted in blocks:
            out.append(header)
            out += [f"- {it}" for it in items]
            if omitted:
                out.append(f"- ({omitted} more check{'s' if omitted != 1 else ''} in the specs)")
        if dropped_blocks:
            out.append(f"(Checks for {dropped_blocks} more feature{'s' if dropped_blocks != 1 else ''} are in the specs.)")
    out += ["", f"Commit {sha[:12]} (Settings → Status shows it)."]
    return "\n".join(out)


def assemble(purpose, since, features, fixes, internal, sha, cap=CAP):
    """features: [(fid, title, [items])]. Cut to cap as F26 §4.4 orders it."""
    changed = [f"{fid}: {title}" for fid, title, _ in features] + [f"Fixed: {t}" for _, t in fixes]
    blocks = [[f"{fid}: {title}", list(items), 0] for fid, title, items in features if items]
    cut_changed = dropped = 0
    text = render(purpose, since, changed, internal, blocks, sha)
    while units(text) > cap:
        if blocks:
            last = blocks[-1]
            if len(last[1]) > 1:
                last[1].pop()
                last[2] += 1
            else:
                blocks.pop()
                dropped += 1
        elif changed:
            changed.pop()
            cut_changed += 1
        else:
            break
        text = render(purpose, since, changed, internal, blocks, sha, cut_changed, dropped)
    if units(text) > cap:                       # only a pathological purpose gets here
        while units(text) > cap - 1:
            text = text[:-1]
        text += "…"
    return text


def make_notes(repo, head="HEAD", purpose=None, require_purpose=False, build=None,
               baseline=None, issue_title=gh_issue_title, cap=CAP):
    purpose = check_purpose(purpose, require_purpose)
    head_sha = resolve(repo, head)
    if not head_sha:
        raise NotesError(f"{head} is not a commit")
    base = resolve_baseline(repo, head_sha, below=build, override=baseline)
    feats, fixes, internal = classify(repo, base.sha, head_sha, issue_title)
    features = [(fid, spec_title(text, fid), device_checks(text)) for fid, text in feats.items()]
    return assemble(purpose, base.label, features, fixes, internal, head_sha, cap), base


# ----- App Store Connect -----

def der_to_raw(der, size=32):
    """An ECDSA DER signature (SEQUENCE of two INTEGERs) as JWS's r||s."""
    def read_len(b, i):
        n = b[i]
        if n < 0x80:
            return n, i + 1
        k = n & 0x7F
        return int.from_bytes(b[i + 1:i + 1 + k], "big"), i + 1 + k
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    _, i = read_len(der, 1)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n, i = read_len(der, i + 1)
        v = der[i:i + n].lstrip(b"\0")
        if len(v) > size:
            raise ValueError("integer too long")
        parts.append(v.rjust(size, b"\0"))
        i += n
    return b"".join(parts)


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def make_jwt(key_id, issuer, key_path, now=None, lifetime=900):
    now = int(now if now is not None else time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {"iss": issuer, "iat": now, "exp": now + lifetime, "aud": "appstoreconnect-v1"}
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     b64url(json.dumps(claims, separators=(",", ":")).encode()))
    r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                       input=signing_input.encode(), capture_output=True)
    if r.returncode != 0:
        raise NotesError(f"openssl could not sign with {key_path}: {r.stderr.decode().strip()}")
    return signing_input + "." + b64url(der_to_raw(r.stdout))


def read_kv(path):
    out = {}
    if os.path.exists(path):
        for line in read_text(path).splitlines():
            m = re.match(r"^\s*([A-Z_][A-Z0-9_]*)=(.*?)\s*$", line)
            if m:
                out[m.group(1)] = m.group(2).strip("'\"")
    return out


def app_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def credentials():
    kv = read_kv(os.path.join(app_dir(), ".asc-key"))
    key_id = os.environ.get("ASC_KEY_ID") or kv.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID") or kv.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        raise NotesError("no App Store Connect API key: app/.asc-key needs ASC_KEY_ID and "
                         "ASC_ISSUER_ID (docs/TESTFLIGHT.md)")
    path = (os.environ.get("ASC_KEY_PATH") or kv.get("ASC_KEY_PATH") or
            os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    if not os.path.exists(path):
        raise NotesError(f"no API key file at {path}")
    return key_id, issuer, path


def bundle_id():
    if os.environ.get("BUNDLE_ID"):
        return os.environ["BUNDLE_ID"]
    for name in ("Local.xcconfig", "Latchkey.xcconfig"):
        path = os.path.join(app_dir(), name)
        if os.path.exists(path):
            for line in read_text(path).splitlines():
                m = re.match(r"^\s*LATCHKEY_BUNDLE_ID\s*=\s*([\w.-]+)", line)
                if m:
                    return m.group(1)
    return "net.lixom.latchkey"


class ASC:
    def __init__(self, key_id, issuer, key_path, base=None):
        self.key_id, self.issuer, self.key_path = key_id, issuer, key_path
        self.base = (base or os.environ.get("ASC_API_BASE") or API_BASE).rstrip("/")

    def call(self, method, path, query=None, body=None):
        url = self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + make_jwt(self.key_id, self.issuer, self.key_path),
            "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                errs = json.loads(detail).get("errors", [])
                detail = "; ".join(f"{x.get('title', '')}: {x.get('detail', '')}" for x in errs) or detail
            except ValueError:
                pass
            raise NotesError(f"App Store Connect {method} {path}: HTTP {e.code}: {detail}")
        except urllib.error.URLError as e:
            raise NotesError(f"App Store Connect {method} {path}: {e.reason}")
        return json.loads(raw) if raw else {}

    def app_id(self, bundle):
        data = self.call("GET", "/v1/apps", {"filter[bundleId]": bundle, "limit": "1"})["data"]
        if not data:
            raise NotesError(f"App Store Connect has no app with bundle id {bundle}")
        return data[0]["id"]

    def build(self, app, number):
        data = self.call("GET", "/v1/builds", {"filter[app]": app, "filter[version]": str(number),
                                               "limit": "1"})["data"]
        return data[0] if data else None

    def latest_build(self, app):
        data = self.call("GET", "/v1/builds", {"filter[app]": app, "sort": "-uploadedDate",
                                               "limit": "1"})["data"]
        return data[0]["attributes"]["version"] if data else None

    def localizations(self, build_id):
        return self.call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]


def client():
    return ASC(*credentials())


def set_notes(asc, bundle, number, notes, wait=DEFAULT_WAIT, poll=POLL, dry_run=False,
              log=print, sleep=time.sleep, clock=time.monotonic):
    if notes is None and not dry_run:
        raise NotesError("no notes to set")
    if notes is not None and units(notes) > CAP:
        raise NotesError(f"the notes are {units(notes)} units long; App Store Connect takes {CAP}")
    app = asc.app_id(bundle)
    deadline, last = clock() + wait, object()
    while True:
        b = asc.build(app, number)
        state = b["attributes"].get("processingState") if b else None
        if state != last:
            log(f"build {number}: {state or 'not on App Store Connect yet'}")
            last = state
        if state == "VALID" or (dry_run and b):
            break
        if state in ("FAILED", "INVALID"):
            raise NotesError(f"build {number} processing ended {state}; no notes set")
        if dry_run:
            log("dry run: nothing written")
            return None
        left = deadline - clock()
        if left <= 0:
            raise ProcessingTimeout(
                f"build {number} was still {state or 'not visible'} after {wait} s. The upload "
                f"succeeded; the notes are not set yet. Run: make tf-notes BUILD={number}")
        sleep(min(poll, left))
    locs = asc.localizations(b["id"])
    loc = next((x for x in locs if x["attributes"].get("locale") == LOCALE), None)
    current = (loc or {}).get("attributes", {}).get("whatToTest")
    if dry_run:
        log(f"current What to Test ({LOCALE}): {current!r}")
        if notes is None:
            log("dry run: no notes for this build; nothing written")
        else:
            log(f"dry run: would {'PATCH' if loc else 'POST'} {units(notes)} units; nothing written")
        return None
    if loc:
        res = asc.call("PATCH", f"/v1/betaBuildLocalizations/{loc['id']}", body={"data": {
            "type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatToTest": notes}}})
    else:
        res = asc.call("POST", "/v1/betaBuildLocalizations", body={"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": LOCALE, "whatToTest": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})
    got = res.get("data", {}).get("attributes", {}).get("whatToTest")
    if got != notes:
        raise NotesError(f"App Store Connect answered with different notes: {got!r}")
    log(f"build {number}: What to Test set ({units(notes)} units, {LOCALE})")
    return res


def notes_from_tag(repo, number):
    """The message of tag tf/<n>, else the notes saved beside the export."""
    tag = f"{TAG_PREFIX}{number}"
    if git(repo, "cat-file", "-t", tag, check=False).strip() == "tag":
        return git(repo, "tag", "-l", "--format=%(contents)", tag).rstrip()
    saved = os.path.join(app_dir(), "build", "testflight-notes", f"{number}.txt")
    if os.path.exists(saved):
        return read_text(saved).rstrip()
    raise NotesError(f"no annotated tag {tag} and no app/build/testflight-notes/{number}.txt; "
                     "pass --notes-file")


def warn_if_asc_is_newer(base, log=lambda m: print(m, file=sys.stderr)):
    try:
        asc = client()
        latest = asc.latest_build(asc.app_id(bundle_id()))
    except NotesError as e:
        log(f"warning: could not ask App Store Connect for its newest build: {e}")
        return
    if latest and base.build and int(latest) > base.build:
        log(f"warning: App Store Connect has build {latest}, newer than the baseline "
            f"({base.label}, {base.source}), and no {TAG_PREFIX}{latest} tag is here. The notes "
            f"repeat what it had. Fetch its tag (git fetch --tags) or pass BASELINE=<its commit>.")


# ----- command line -----

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=None, help="repository root (default: this script's)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("notes")
    n.add_argument("--purpose", default=os.environ.get("PURPOSE"))
    n.add_argument("--require-purpose", action="store_true")
    n.add_argument("--head", default="HEAD")
    n.add_argument("--build", type=int, help="the build being made; older tags only")
    n.add_argument("--baseline", default=os.environ.get("BASELINE") or None)
    n.add_argument("--out", action="append", default=[])
    n.add_argument("--quiet", action="store_true", help="do not print the notes")
    n.add_argument("--check-asc", action="store_true",
                   help="warn if App Store Connect has a build newer than the baseline")
    s = sub.add_parser("set")
    s.add_argument("--build", type=int, required=True)
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--notes-file")
    g.add_argument("--from-tag", action="store_true")
    s.add_argument("--wait", type=int, default=int(os.environ.get("TF_NOTES_WAIT") or DEFAULT_WAIT))
    s.add_argument("--poll", type=int, default=POLL)
    s.add_argument("--dry-run", action="store_true")
    sub.add_parser("latest")
    a = ap.parse_args(argv)
    repo = a.repo or git(app_dir(), "rev-parse", "--show-toplevel").strip()
    try:
        if a.cmd == "notes":
            text, base = make_notes(repo, a.head, a.purpose, a.require_purpose, a.build, a.baseline)
            print(f"notes: since {base.label} ({base.source}, {base.sha[:12]}), {units(text)} of {CAP}",
                  file=sys.stderr)
            if a.check_asc:
                warn_if_asc_is_newer(base)
            for path in a.out:
                os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text + "\n")
            if not a.quiet:
                print(text)
        elif a.cmd == "set":
            try:
                notes = (notes_from_tag(repo, a.build) if a.from_tag
                         else read_text(a.notes_file).rstrip())
            except NotesError as e:
                if not a.dry_run:
                    raise
                print(f"dry run: {e}; looking the build up anyway", file=sys.stderr)
                notes = None
            set_notes(client(), bundle_id(), a.build, notes, a.wait, a.poll, a.dry_run)
        elif a.cmd == "latest":
            asc = client()
            print(asc.latest_build(asc.app_id(bundle_id())) or "(no builds)")
    except ProcessingTimeout as e:
        print(f"error: {e}", file=sys.stderr)
        return 3
    except NotesError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
