#!/usr/bin/env python3
"""Host tests for scripts/tf_notes.py, the TestFlight notes (F26 §6).

Each test builds a throwaway git repository with specs, a README and commits
and runs the real generator against it. The App Store Connect calls go to a
fake HTTP server in this process; nothing reaches Apple. TF_NOTES_PY points
at another copy of tf_notes.py, which is how a mutation is shown to fail.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.environ.get("TF_NOTES_PY") or os.path.join(HERE, "tf_notes.py")
spec = importlib.util.spec_from_file_location("tf_notes", MODULE)
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)

os.environ["TF_NOTES_OFFLINE"] = "1"      # never ask gh from a test


def no_issue(repo, k):
    return None


def scratch_base():
    """TMPDIR, unless git cannot work there: an agent session's sandboxed
    scratch TMPDIR fails `git init` with "Invalid path ... Operation not
    permitted" (measured 2026-10-09). /tmp then."""
    probe = tempfile.mkdtemp(prefix="tf-notes-probe-")
    ok = subprocess.run(["git", "-C", probe, "init", "-q"], capture_output=True).returncode == 0
    shutil.rmtree(probe, ignore_errors=True)
    return None if ok else "/tmp"


SCRATCH = scratch_base()


F1 = """# F1 — Make the widget blink

| | |
|---|---|
| **Status** | built |

## 5. Design

1. Not a device check item.

## 6. Device check

1. Open the dashboard. The widget
   blinks twice (§4.2).
2. Tap **Stop**: it stops, as `WidgetView` says.
3. Pull Settings → Diagnostics → Logs and find the blink line (owner only)

Shown to fail by turning it off.

## 7. Acceptance criteria

1. Not a device check item either.
"""

F2 = """# F2 — The comment and the measurement disagree

| | |
|---|---|
| **Status** | built |
| **Testers** | The bottom of the page is no longer cut off |

## 6. Tests

- **Unit:** something.
- **Device check (owed):**
  1. Scroll to the bottom. Nothing is hidden behind the home bar.
  2. Rotate to landscape (§5): the same.
- **Not in a suite:** the keyboard.

## 7. More
"""

F3 = """# F3 — Something specced, never built

## 6. Device check

1. Should never appear.
"""

README = """# Feature specs

| # | Feature | Status |
|---|---|---|
| [F1](F1-blink.md) | Blink | built |
| [F2](F2-bottom.md) | The bottom (issue #7) | built |
| [F3](F3-unbuilt.md) | Unbuilt | spec |
"""


class Repo:
    def __init__(self):
        self.path = tempfile.mkdtemp(prefix="tf-notes-test-", dir=SCRATCH)
        self.git("init", "-q", "-b", "main")
        self.write("docs/features/README.md", README)
        self.write("docs/features/F1-blink.md", F1)
        self.write("docs/features/F2-bottom.md", F2)
        self.write("docs/features/F3-unbuilt.md", F3)
        self.write("app/App/Main.swift", "// 0\n")
        self.base = self.commit("docs: initial")

    def git(self, *args):
        p = subprocess.run(["git", "-C", self.path, "-c", "user.name=t", "-c", "user.email=t@invalid",
                            "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
                            "-c", "core.hooksPath=/dev/null", *args],
                           capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)}: {p.stderr.strip()}")
        return p.stdout.strip()

    def write(self, rel, text):
        p = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)

    def append(self, rel, text):
        p = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(text)

    def commit(self, message, files=None, **kw):
        files = dict(files or {}, **{k.replace("__", "/"): v for k, v in kw.items()})
        for rel, text in files.items():
            self.append(rel, text)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def history(self, *rows):
        body = "# TestFlight\n\n## Build history\n\n| Build | Commit | Note |\n|---|---|---|\n"
        body += "".join(f"| {b} | {c[:12]} | seed |\n" for b, c in rows)
        body += "\n## Testers\n\n| 999999999999 | deadbeef | not in the table |\n"
        self.write("docs/TESTFLIGHT.md", body)

    def notes(self, **kw):
        kw.setdefault("purpose", "Testing")
        kw.setdefault("issue_title", no_issue)
        return tf.make_notes(self.path, **kw)

    def close(self):
        shutil.rmtree(self.path, ignore_errors=True)


class Baselines(unittest.TestCase):
    def setUp(self):
        self.r = Repo()

    def tearDown(self):
        self.r.close()

    def test_newest_ancestor_tag_wins_over_an_older_table_row(self):
        r = self.r
        r.history((202601010000, r.base))
        r.commit("docs: seed")
        a = r.commit("browser: one", app__App__Main_swift="// 1\n")
        r.git("tag", "-a", "-m", "n", "tf/202602010000", a)
        b = r.commit("browser: two", app__App__Main_swift="// 2\n")
        r.git("tag", "-a", "-m", "n", "tf/202603010000", b)
        # A newer tag on a side branch is not an ancestor of main's HEAD.
        r.git("checkout", "-q", "-b", "side", a)
        side = r.commit("browser: side", app__App__Main_swift="// side\n")
        r.git("tag", "-a", "-m", "n", "tf/202609010000", side)
        r.git("checkout", "-q", "main")
        head = r.commit("browser: three", app__App__Main_swift="// 3\n")
        base = tf.resolve_baseline(r.path, head)
        self.assertEqual((base.build, base.sha, base.source), (202603010000, b, "tag tf/202603010000"))
        # Making build 202603010000 again (tf-notes for it) starts from the tag before it.
        base = tf.resolve_baseline(r.path, head, below=202603010000)
        self.assertEqual(base.build, 202602010000)

    def test_the_table_seeds_the_first_build_and_nothing_refuses(self):
        r = self.r
        with self.assertRaises(tf.NotesError) as e:
            tf.resolve_baseline(r.path, r.base)
        self.assertIn("BASELINE=", str(e.exception))
        r.history((202601010000, r.base))
        head = r.commit("docs: seed")
        base = tf.resolve_baseline(r.path, head)
        self.assertEqual((base.build, base.sha), (202601010000, r.base))
        self.assertIn("docs/TESTFLIGHT.md", base.source)
        text, _ = r.notes()
        self.assertIn("What changed since build 202601010000:", text)
        # A row naming a commit that is not an ancestor is ignored.
        self.assertEqual(tf.history_rows(tf.read_text(os.path.join(r.path, "docs/TESTFLIGHT.md"))),
                         [(202601010000, r.base[:12])])

    def test_baseline_override(self):
        r = self.r
        head = r.commit("browser: x", app__App__Main_swift="// x\n")
        base = tf.resolve_baseline(r.path, head, override=r.base)
        self.assertEqual((base.sha, base.build), (r.base, None))
        self.assertEqual(base.label, "commit " + r.base[:12])


class Detection(unittest.TestCase):
    def setUp(self):
        self.r = Repo()
        self.r.history((202601010000, self.r.base))
        self.r.commit("docs: seed")

    def tearDown(self):
        self.r.close()

    def test_only_shipped_changes_are_listed(self):
        r = self.r
        # F3's spec lands with a Spec: line but touches docs only: F25's case on main.
        r.commit("docs: f3 spec\n\nSpec: docs/features/F3-unbuilt.md", docs__features__F3_extra_md="x\n")
        # A test-only commit for F1 does not ship.
        r.commit("l1: test f1\n\nSpec: docs/features/F1-blink.md", app__UITests__T_swift="// t\n")
        # F1 ships.
        r.commit("browser: blink\n\nSpec: docs/features/F1-blink.md", app__App__Blink_swift="// b\n")
        # Fixes #7 is claimed by F2's README row.
        r.commit("browser: pad the bottom\n\nFixes #7", app__App__Pad_swift="// p\n")
        # An unclaimed fix: the issue's title, area dropped.
        r.commit("browser: ask for playback\n\nFixes #10", app__App__Audio_swift="// a\n")
        # Without a title (no gh), the subject minus its area.
        r.commit("tsnet: close a hole\n\nCloses #11", app__TSNet__Bus_swift="// h\n")
        # Internal: ships, claims nothing.
        r.commit("app: sort a key", files={"app/Latchkey.xcodeproj/project.pbxproj": "x\n"})
        r.commit("scripts: a script", app__scripts__s_sh="x\n")
        titles = {10: "browser: dashboard read-aloud plays nothing on iPhone"}
        text, _ = r.notes(issue_title=lambda repo, k: titles.get(k))
        changed = text.split("What changed since build 202601010000:\n")[1].split("\n\n")[0]
        self.assertEqual(changed.splitlines(), [
            "- F1: Make the widget blink",
            "- F2: The bottom of the page is no longer cut off",
            "- Fixed: dashboard read-aloud plays nothing on iPhone",
            "- Fixed: close a hole",
            "- Plus 1 internal change with nothing new to try.",
        ])
        self.assertNotIn("F3", text)
        self.assertNotIn("Should never appear", text)

    def test_nothing_shipped(self):
        r = self.r
        r.commit("docs: f3 spec\n\nSpec: docs/features/F3-unbuilt.md", docs__x_md="x\n")
        text, _ = r.notes()
        self.assertIn("What changed since build 202601010000:\n- No changes to the app.\n", text)
        self.assertNotIn("Things to try", text)
        head = r.git("rev-parse", "HEAD")
        self.assertTrue(text.endswith(f"Commit {head[:12]} (Settings → Status shows it)."))


class Extraction(unittest.TestCase):
    def test_heading_section(self):
        self.assertEqual(tf.device_checks(F1), [
            "Open the dashboard. The widget blinks twice.",
            "Tap Stop: it stops, as WidgetView says.",
        ])

    def test_bold_bullet_section(self):
        self.assertEqual(tf.device_checks(F2), [
            "Scroll to the bottom. Nothing is hidden behind the home bar.",
            "Rotate to landscape: the same.",
        ])

    def test_no_section(self):
        self.assertEqual(tf.device_checks("# F9 — x\n\n## 6. Tests\n\n1. a\n"), [])

    def test_section_ends_at_the_next_heading_even_without_a_blank_line(self):
        text = "## 6. Device check\n1. one\n2. two\n## 7. Next\n1. three\n"
        self.assertEqual(tf.device_checks(text), ["one", "two"])

    def test_titles(self):
        self.assertEqual(tf.spec_title(F1, "F1"), "Make the widget blink")
        self.assertEqual(tf.spec_title(F2, "F2"), "The bottom of the page is no longer cut off")
        placeholder = "# F4 — Real title\n\n| **Testers** | <optional: one line> |\n"
        self.assertEqual(tf.spec_title(placeholder, "F4"), "Real title")


class Cap(unittest.TestCase):
    def test_forty_long_features_fit_in_4000(self):
        item = "Swipe in from the left edge and watch the drawer open — ✓ " * 4
        features = [(f"F{i}", f"Feature number {i} does a thing", [item] * 8) for i in range(1, 41)]
        fixes = [(k, f"bug {k} is gone") for k in range(1, 30)]
        text = tf.assemble("Purpose — keep me", "build 1", features, fixes, 3, "0" * 40)
        self.assertLessEqual(tf.units(text), 4000)
        self.assertGreater(tf.units(text), 3500)          # cut to fit, not emptied
        self.assertTrue(text.startswith("Why this build: Purpose — keep me\n\nWhat changed since build 1:\n"))
        self.assertIn("more check", text)
        self.assertIn("\nThings to try:\nF1: Feature number 1 does a thing\n", text)
        self.assertTrue(text.endswith("(Settings → Status shows it)."))

    def test_what_changed_is_cut_last(self):
        features = [(f"F{i}", "x" * 120, ["y" * 300]) for i in range(1, 60)]
        text = tf.assemble("P", "build 1", features, [], 0, "0" * 40)
        self.assertLessEqual(tf.units(text), 4000)
        self.assertNotIn("Things to try", text.split("Checks for")[0].split("What changed")[0])
        self.assertIn("- and ", text)
        self.assertIn("more features are in the specs", text)

    def test_short_notes_are_untouched(self):
        text = tf.assemble("P", "build 1", [("F1", "t", ["a", "b"])], [], 0, "0" * 40)
        self.assertIn("- a\n- b\n", text)
        self.assertNotIn("more", text)


class Purpose(unittest.TestCase):
    def setUp(self):
        self.r = Repo()
        self.r.history((202601010000, self.r.base))
        self.r.commit("docs: seed")

    def tearDown(self):
        self.r.close()

    def cli(self, *args, env=None):
        e = dict(os.environ, TF_NOTES_OFFLINE="1")
        e.pop("PURPOSE", None)
        e.update(env or {})
        return subprocess.run([sys.executable, MODULE, "--repo", self.r.path, *args],
                              capture_output=True, text=True, env=e)

    def test_missing_purpose_refuses_an_upload(self):
        for args, env in [((), {}), (("--purpose", "  "), {}), ((), {"PURPOSE": ""})]:
            p = self.cli("notes", "--require-purpose", *args, env=env)
            self.assertEqual(p.returncode, 1, (args, env, p.stdout))
            self.assertIn("no PURPOSE", p.stderr)
            self.assertEqual(p.stdout, "")

    def test_too_long_purpose_refuses_always(self):
        p = self.cli("notes", "--purpose", "x" * 501)
        self.assertEqual(p.returncode, 1)
        self.assertIn("501 characters", p.stderr)

    def test_purpose_from_environment_and_optional_without_upload(self):
        p = self.cli("notes", "--require-purpose", env={"PURPOSE": "Don't skip the apostrophe"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("Why this build: Don't skip the apostrophe\n"))
        p = self.cli("notes")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("Why this build: (no purpose given)\n"))

    def test_out_files(self):
        out = os.path.join(self.r.path, "build", "n.txt")
        p = self.cli("notes", "--purpose", "P", "--quiet", "--out", out)
        self.assertEqual((p.returncode, p.stdout), (0, ""))
        self.assertTrue(tf.read_text(out).startswith("Why this build: P\n"))


# ----- App Store Connect, against a fake -----

def make_key(directory):
    pem = subprocess.run(["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout"],
                         check=True, capture_output=True).stdout
    p8 = subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt"], input=pem,
                        check=True, capture_output=True).stdout
    key = os.path.join(directory, "AuthKey_TEST.p8")
    with open(key, "wb") as f:
        f.write(p8)
    pub = os.path.join(directory, "pub.pem")
    subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)
    return key, pub


def raw_to_der(raw):
    def integer(b):
        b = b.lstrip(b"\0") or b"\0"
        if b[0] & 0x80:
            b = b"\0" + b
        return bytes([0x02, len(b)]) + b
    body = integer(raw[:32]) + integer(raw[32:])
    return bytes([0x30, len(body)]) + body


def b64d(s):
    import base64
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class FakeASC:
    """Answers the five calls tf_notes makes; states are served in order."""

    def __init__(self, states, localizations):
        self.states, self.locs, self.requests = list(states), localizations, []
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code, obj):
                b = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def handle_any(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n)) if n else None
                fake.requests.append((self.command, self.path, body, self.headers.get("Authorization")))
                if not (self.headers.get("Authorization") or "").startswith("Bearer "):
                    return self.reply(401, {"errors": [{"title": "unauthorized", "detail": "no token"}]})
                path = self.path.split("?")[0]
                if self.command == "GET" and path == "/v1/apps":
                    return self.reply(200, {"data": [{"id": "APP1", "type": "apps"}]})
                if self.command == "GET" and path == "/v1/builds":
                    st = fake.states.pop(0) if len(fake.states) > 1 else fake.states[0]
                    data = [] if st is None else [{"id": "B1", "type": "builds",
                                                   "attributes": {"version": "202610100000",
                                                                  "processingState": st}}]
                    return self.reply(200, {"data": data})
                if self.command == "GET" and path == "/v1/builds/B1/betaBuildLocalizations":
                    return self.reply(200, {"data": fake.locs})
                if self.command in ("PATCH", "POST"):
                    return self.reply(200 if self.command == "PATCH" else 201,
                                      {"data": {"id": "L9", "type": "betaBuildLocalizations",
                                                "attributes": body["data"]["attributes"]}})
                return self.reply(404, {"errors": [{"title": "not found", "detail": self.path}]})

            do_GET = do_PATCH = do_POST = handle_any

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def writes(self):
        return [r for r in self.requests if r[0] in ("PATCH", "POST")]

    def close(self):
        self.server.shutdown()


class AppStoreConnect(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="tf-notes-key-")
        cls.key, cls.pub = make_key(cls.dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def fake(self, states, locs):
        f = FakeASC(states, locs)
        self.addCleanup(f.close)
        return f, tf.ASC("KEYID", "ISSUER", self.key, base=f.url)

    def test_jwt_verifies_with_the_public_key(self):
        token = tf.make_jwt("KEYID", "ISSUER", self.key, now=1_000_000)
        h, c, s = token.split(".")
        self.assertEqual(json.loads(b64d(h)), {"alg": "ES256", "kid": "KEYID", "typ": "JWT"})
        self.assertEqual(json.loads(b64d(c)), {"iss": "ISSUER", "iat": 1_000_000, "exp": 1_000_900,
                                               "aud": "appstoreconnect-v1"})
        raw = b64d(s)
        self.assertEqual(len(raw), 64)
        sig = os.path.join(self.dir, "sig.der")
        with open(sig, "wb") as f:
            f.write(raw_to_der(raw))
        v = subprocess.run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", sig],
                           input=(h + "." + c).encode(), capture_output=True)
        self.assertEqual(v.returncode, 0, v.stdout + v.stderr)

    def test_existing_localization_is_patched(self):
        f, asc = self.fake(["VALID"], [{"id": "L1", "type": "betaBuildLocalizations",
                                        "attributes": {"locale": "en-US", "whatToTest": None}},
                                       {"id": "L2", "type": "betaBuildLocalizations",
                                        "attributes": {"locale": "sv", "whatToTest": None}}])
        tf.set_notes(asc, "net.example", 202610100000, "Why this build: x", log=lambda m: None)
        self.assertEqual(f.writes(), [("PATCH", "/v1/betaBuildLocalizations/L1", {"data": {
            "type": "betaBuildLocalizations", "id": "L1", "attributes": {"whatToTest": "Why this build: x"}}},
            f.writes()[0][3])])
        self.assertTrue(all(r[3].startswith("Bearer ") for r in f.requests))
        self.assertIn("filter%5BbundleId%5D=net.example", f.requests[0][1])
        self.assertIn("filter%5Bversion%5D=202610100000", f.requests[1][1])

    def test_no_localization_is_posted(self):
        f, asc = self.fake(["VALID"], [])
        tf.set_notes(asc, "net.example", 202610100000, "N", log=lambda m: None)
        (method, path, body, _), = f.writes()
        self.assertEqual((method, path), ("POST", "/v1/betaBuildLocalizations"))
        self.assertEqual(body["data"]["attributes"], {"locale": "en-US", "whatToTest": "N"})
        self.assertEqual(body["data"]["relationships"], {"build": {"data": {"type": "builds", "id": "B1"}}})

    def test_waits_through_processing(self):
        f, asc = self.fake([None, "PROCESSING", "PROCESSING", "VALID"], [])
        t, sleeps = [0.0], []

        def sleep(s):
            sleeps.append(s)
            t[0] += s
        tf.set_notes(asc, "b", 202610100000, "N", wait=600, poll=30, log=lambda m: None,
                     sleep=sleep, clock=lambda: t[0])
        self.assertEqual(sleeps, [30, 30, 30])
        self.assertEqual(len(f.writes()), 1)

    def test_times_out_without_writing(self):
        f, asc = self.fake(["PROCESSING"], [])
        t = [0.0]

        def sleep(s):
            t[0] += s
        with self.assertRaises(tf.ProcessingTimeout) as e:
            tf.set_notes(asc, "b", 202610100000, "N", wait=100, poll=30, log=lambda m: None,
                         sleep=sleep, clock=lambda: t[0])
        self.assertIn("make tf-notes BUILD=202610100000", str(e.exception))
        self.assertIn("upload succeeded", str(e.exception))
        self.assertEqual(f.writes(), [])

    def test_timeout_exit_status_from_the_command_line(self):
        f, _ = self.fake(["PROCESSING"], [])
        notes = os.path.join(self.dir, "n.txt")
        with open(notes, "w") as fh:
            fh.write("N\n")
        env = dict(os.environ, ASC_KEY_ID="KEYID", ASC_ISSUER_ID="ISSUER", ASC_KEY_PATH=self.key,
                   ASC_API_BASE=f.url, BUNDLE_ID="net.example")
        p = subprocess.run([sys.executable, MODULE, "--repo", HERE, "set", "--build", "202610100000",
                            "--notes-file", notes, "--wait", "0"], capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 3, p.stderr)
        self.assertIn("make tf-notes BUILD=202610100000", p.stderr)
        self.assertEqual(f.writes(), [])

    def test_failed_processing_writes_nothing(self):
        f, asc = self.fake(["FAILED"], [])
        with self.assertRaises(tf.NotesError) as e:
            tf.set_notes(asc, "b", 202610100000, "N", wait=0, log=lambda m: None, sleep=lambda s: None)
        self.assertIn("FAILED", str(e.exception))
        self.assertEqual(f.writes(), [])

    def test_dry_run_writes_nothing(self):
        f, asc = self.fake(["PROCESSING"], [{"id": "L1", "attributes": {"locale": "en-US", "whatToTest": "old"}}])
        logs = []
        tf.set_notes(asc, "b", 202610100000, "N", dry_run=True, log=logs.append)
        self.assertEqual(f.writes(), [])
        self.assertTrue(any("would PATCH" in m for m in logs), logs)

    def test_over_long_notes_are_refused_before_any_call(self):
        f, asc = self.fake(["VALID"], [])
        with self.assertRaises(tf.NotesError):
            tf.set_notes(asc, "b", 1, "x" * 4001, log=lambda m: None)
        self.assertEqual(f.requests, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
