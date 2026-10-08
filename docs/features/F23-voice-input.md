# F23 — Voice input in the dashboard

| | |
|---|---|
| **Status** | designed (speculative): awaiting the crash log |
| **Requested** | 2026-10-07, by Olof ([issue #9](https://github.com/olofj/latchkey/issues/9)): "I tried using voice input on a remote session and latchkey crashed for me." |
| **Revision** | none yet; §4 W2 widens what the web view may do (a capture grant), so it gets an R-entry when built |
| **Touches** | App/Browser (`BrowserViewModel` UI delegate), the app target's Info.plist keys, `App/PrivacyInfo.xcprivacy`, the L1 fake dashboard, the session suite |

KiroCrew citations are to the installed 0.7.2 package,
`~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/` (written `kc/`
below). The session suite's pinned 0.7.1 wheel ships the same flow
(`/api/ws/stt` and `pcm-worklet` are both in it).

**What waits on the crash log.** §1's choice between hypotheses, and
therefore whether W1–W2 *are* the fix or only the support work around some
other fix. W1–W2 are needed either way: voice input cannot work in Latchkey
today, crash or no crash (§1.1). Nothing below should be built before the
log is read, except that W1–W2 are safe to build regardless.

## 1. Why

### 1.1 What is known

- **No microphone usage string.** The app target declares only
  `NSCameraUsageDescription` and `NSLocalNetworkUsageDescription`
  (`app/Latchkey.xcodeproj/project.pbxproj:394-395`, `:456-457`,
  `:499-500`). No `NSMicrophoneUsageDescription`, no
  `NSSpeechRecognitionUsageDescription`.
- **No capture decision.** The `WKUIDelegate` extension
  (`app/App/Browser/BrowserViewModel.swift:1160-1231`) implements the context
  menu and `createWebViewWith` only. There is no
  `webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)`,
  so WebKit falls back to its own per-page prompt. Nothing in `app/App` or
  `app/ShareExtension` mentions `AVAudioSession` or the microphone.
- **What the dashboard does.** The mic button is shown when
  `navigator.mediaDevices.getUserMedia` exists and `MediaRecorder` supports
  one of webm/mp4/ogg (`kc/static/dist/assets/App-e17PGpKz.js`, `var mL=`).
  That gate is **client-side only**: it does not ask the gateway whether STT
  is enabled. Tapping it calls `getUserMedia({audio:true})`, or with a saved
  `deviceId` first and `{audio:true}` as the fallback
  (`dictationText-DBjp56l6.js`, `async function o`), then
  `new AudioContext()` + `audioWorklet.addModule('/pcm-worklet.js')` and
  streams PCM to `${wss}//${location.host}/api/ws/stt`
  (`App-e17PGpKz.js`); if the worklet fails it falls back to
  `MediaRecorder` and `POST /api/stt/transcribe`
  (`kc/dashboard/routes/memory.py:37-38`). No Web Speech API.
- **The STT socket.** `GET /api/ws/stt` (`kc/dashboard/stt_stream.py:1226`)
  requires a matching `Origin` (`check_origin(request, require=True)`,
  `:1235`), answers 503 when streaming STT is off or busy (`:1243-1250`),
  and runs a 30 s heartbeat (`:1253`).

### 1.2 "Remote session": both meanings reach the same origin

- **A remote gateway selected in Latchkey** (the issue's reading: byskebox
  as the gateway). The page origin *is* byskebox; the STT socket goes to
  byskebox through the SOCKS relay like `/api/ws` does.
- **A peer chat through the dashboard's Instances switcher.** The hub
  proxies only the peer's `api/chat` and `api/stream`
  (`kc/dashboard/handlers_instances.py:1190-1193`, route
  `kc/dashboard/routes/connections.py:143`), and deliberately refuses a
  WebSocket upgrade (`:1174-1178`). The STT socket is built from
  `location.host`, so it goes to the **hub**, which transcribes, and only the
  text crosses the proxy as a chat message. Inference: the hub's STT
  config, not the peer's, decides whether dictation works there.

Either way `/api/ws/stt` is a WebSocket on the page's own authority, which
F6 rule 4 already admits (`app/App/Browser/ContentRules.swift:71-72`), and
`/pcm-worklet.js` is a same-origin script (rule 3, `:69-70`). The tailnet
host is already in the split tunnel. **No F6 or relay change is needed.**
Inference: "remote" is probably incidental, since the button's gate does
not depend on the gateway. The device check (§6.2) asks it directly.

### 1.3 Crash hypotheses

The `.ips` file's **name** is the first fork: `Latchkey-*.ips` is our
process; `com.apple.WebKit.WebContent-*` or `com.apple.WebKit.GPU-*` is a
WebKit process, which the owner sees as the page blanking and reloading
(`webViewWebContentProcessDidTerminate`, `BrowserViewModel.swift:1368`), not
as the app vanishing. A `JetsamEvent-*.ips` is memory.

| # | Hypothesis | Confirmed by | Refuted by |
|---|---|---|---|
| H1 | TCC kills the process that touched the mic without a usage string | `"namespace":"TCC"`, `EXC_CRASH (SIGABRT)`, reason "attempted to access privacy-sensitive data without a usage description … NSMicrophoneUsageDescription" | another namespace. Inference: current WebKit checks the key itself and rejects with `NotAllowedError`, which would make H1 unlikely unless that check is missing on the phone's iOS |
| H2 | A WebKit process crash (WebContent or GPU) during capture or AudioWorklet start | a `com.apple.WebKit.*` .ips with frames in `WebCore::…Audio…`, `AudioWorklet`, `CoreAudioCaptureSource`, `RealtimeMediaSource`; our log: "Web content process terminated" and `webContentTerminations` up in Diagnostics | no WebKit .ips around 15:10; app's own .ips present |
| H3 | iOS keyboard dictation, not the dashboard's button | frames in UIKit text input / `UIDictation*` / `_UIKeyboard*` in `Latchkey-*.ips`; Olof says he used the keyboard mic | Olof used the composer's mic button. The keyboard runs dictation out of process and needs no app usage string, so a crash *in our process* from it would be an iOS bug |
| H4 | Audio session conflict with our networking (tsnet, SOCKS relay) | frames in `AVAudioSession`/`AudioToolbox` *and* our TSNet code on the crashing thread, or an `AVAudioSessionErrorCode` assert | no audio frames in our process. Inference: low prior; we never touch `AVAudioSession` and tsnet does no audio |
| H5 | Memory: AudioContext + capture pushed WebContent or the app over the jetsam limit | `JetsamEvent-*.ips` naming Latchkey or WebContent with `"reason":"per-process-limit"` | no jetsam report |
| H6 | A Swift trap in our own code on some side path (e.g. a navigation or popup the mic flow triggers) | `EXC_BREAKPOINT` with a `Latchkey` frame in `BrowserViewModel`/`NavigationPolicy` | none of our frames on the crashed thread |

### 1.4 When the log arrives

| Log says | Then |
|---|---|
| TCC namespace, our process (H1) | W1 *is* the fix; W2 next so it is granted only where intended. Regression test: T1 |
| TCC namespace, a WebKit process (H1 via H2) | same as H1; the app survived, so also check the reload recovered (Diagnostics count) |
| WebKit crash, audio frames (H2) | W1–W2 still needed; then reproduce on the simulator with T2/T3. If it reproduces only with the worklet, record it and file upstream with WebKit; consider nothing app-side beyond W1–W2 |
| UIKit dictation frames (H3) | W1–W2 still needed for the button; the crash is a separate bug with its own issue. Ask Olof for the exact field and steps |
| Audio session / our frames (H4, H6) | read the frame; this spec's W4 becomes real or a new issue is filed for the trap |
| Jetsam (H5) | measure WebContent memory during capture on the simulator; separate issue |
| No `.ips` from 15:10 at all | the "crash" was a WebContent reload with no report; treat as H2/H1 via Diagnostics and the app log |

## 2. What the owner sees

Working: he taps the dashboard's mic button. The first time ever, iOS asks
"Latchkey would like to access the microphone" with our purpose string.
After that, no prompt: the orange dot shows while recording, and the words
appear in the composer as they do in a desktop browser. Other gateways he
switches to get the same, without a new prompt (one origin at a time; the
grant follows the selected gateway).

Failing:
- He declined the iOS prompt: the dashboard shows its own "microphone
  denied" message (it handles `NotAllowedError`). Settings → Privacy &
  Security → Microphone → Latchkey turns it back on. Latchkey says nothing
  extra.
- The gateway has streaming STT off: the dashboard falls back or shows its
  own STT error (503 on `/api/ws/stt`). Not ours to fix.
- A ported gateway the operator has not allowed (F1 §4a): the STT socket is
  refused like `/api/ws`; the existing origin banner already covers it.
- Never: a crash, a blank page, or a second Latchkey-drawn prompt.

## 3. Non-goals

- Camera capture in the page. Denied (W2). The QR scanner stays native.
- Speech recognition in the app (`SFSpeechRecognizer`) or our own mic
  button. The dashboard owns voice input; we only stop blocking it.
- Changing F6's rules or the SOCKS relay (§1.2 shows neither is needed).
- Making the Instances proxy carry STT to a peer. That is KiroCrew's design.
- The share extension: it loads no web page and captures nothing. Its
  Info.plist and privacy manifest are untouched.

## 4. Design — work items, in order

**W1. Microphone usage string.** Add
`INFOPLIST_KEY_NSMicrophoneUsageDescription` to the app target's three
build configurations next to the camera string
(`project.pbxproj:394`, `:456`, `:499`), e.g. "Latchkey uses the
microphone only when you tap voice input in your Kiro Crew dashboard. The
audio goes to your gateway and nowhere else." **No
`NSSpeechRecognitionUsageDescription`:** the dashboard does not use Web
Speech (§1.1) and the app does no recognition; declaring it would add an
App Review question for nothing.

**W2. Capture decision in the UI delegate.** In the `WKUIDelegate`
extension (`BrowserViewModel.swift:1160`), add
`webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)`:
- `.grant` iff `type == .microphone`, `frame.isMainFrame`, and the
  origin's `scheme://host[:port]`, rendered as `GatewayAddress.origin(of:)`
  does, equals `allowedOrigin` (`:221`). Main frame only, because
  `about:srcdoc` widget frames inherit the gateway's origin.
- `.deny` for everything else: camera, camera+mic, a subframe, any other
  origin, and `allowedOrigin == nil` (the error page, mid-switch).
- Pure decision in a `nonisolated static func` beside `NavigationPolicy`
  (e.g. `MediaCapturePolicy.decide(type:isMainFrame:origin:allowedOrigin:)`),
  so it gets host tests in `make test-policy`, and one `os_log` line per
  decision (type, main frame, granted/denied; the origin is already logged
  elsewhere) for the suites to read.
- Prompt: `.grant` rather than `.prompt`. The iOS TCC prompt already asks
  once per app; `.prompt` would add WebKit's own "Allow … to use your
  microphone?" sheet per page load. **Remembered per origin?** Not by us:
  the decision is recomputed from `allowedOrigin` on every request, so
  nothing is persisted and a gateway switch moves the grant with it.

**W3. Confirm the socket path end to end (test, no code).** `/api/ws/stt`
over F6 rule 4 and the relay is expected to work (§1.2). T3 proves it; a
change here only if T3 fails.

**W4. AVAudioSession: none, unless the log or the device says otherwise.**
Inference: WebKit sets the session category itself while capturing. Add
code only if H4 is confirmed, or the device check shows a routing problem
(e.g. a voice reply playing through the earpiece after dictation).

**W5. Instances-switcher path: nothing to build.** Covered by §1.2; the
device check (§6.2 step 3) confirms it on a real hub.

**W6. Privacy copy and manifests.** `App/PrivacyInfo.xcprivacy` has no
collected-data types today. Inference: audio sent only to the owner's own
gateway, never to us or a third party, is not "collected" in Apple's sense,
so the manifest and the App Privacy label stay "no data collected"; Olof
confirms (§8 Q2). Add a sentence to the F19 review notes: the mic is used
only by the dashboard's voice-input button and streams to the reviewer's
own gateway. Expect App Review to exercise the purpose string (5.1.1); F19
already owns the demo-gateway problem. No new Settings screen.

**W7. Record.** DECISIONS.md entry and an R-entry for W2 (the web view may
now capture audio, from one origin).

**Invariants:** split tunnel, `allowFailover = false`, ATS without
exceptions, D1 (audio goes only to the gateway, over the tailnet) and R16 are
untouched. F6's rules are unchanged; bump nothing in `ContentRules`.

## 5. State and migration

Nothing persisted by Latchkey. The TCC grant is iOS's, per app. A user who
denied the prompt keeps that denial across upgrades.

## 6. Tests

### 6.1 Suites

The simulator has a mic path (host audio input), but no suite should depend
on the host's audio. Grant TCC with `xcrun simctl privacy <udid> grant
microphone net.lixom.latchkey` before launch, so no system prompt blocks the
runner; T1 is the exception.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| T0 `MediaCapturePolicy` cases | host (`make test-policy`) | mic + main frame + same origin → grant; camera, subframe, other host, other port, `http` vs `https`, nil origin → deny | flipping `isMainFrame` or dropping the port from the comparison |
| T1 the built app declares the mic string | host or L1 preflight | `Info.plist` in the built `.app` has a non-empty `NSMicrophoneUsageDescription` | the build before W1 (fails today) |
| T2 the dashboard's mic request is granted | L1 (fake dashboard gets a `/voice` fixture page calling `getUserMedia({audio:true})` and reporting the outcome to `/__report`) | the server saw `granted`, and the app logged one grant for the gateway origin | the code before W2: WebKit's own prompt appears and the page never reports, or reports `NotAllowedError` |
| T3 a foreign frame and camera are denied | L1, same fixture | an iframe from a second fake origin and a `{video:true}` call both report `NotAllowedError`; the app logged denials | a policy that grants by type only |
| T4 the STT socket opens through the relay | L1 (fake `/api/ws/stt` echo: accepts binary frames, answers `{"type":"final"}`) | the fixture page sends a frame and gets the reply; the SOCKS log shows the gateway authority | `-UITestBreakContentRules` without rule 4 |
| T5 the real mic button reaches the gateway | session suite (0.7.1 bundle; fake gateway adds an `/api/ws/stt` that records the first binary frame) | after a tap on the composer's mic button, the fake gateway journals an STT connection with a binary frame, and the app did not restart (same process id in the log) | the build before W1–W2 |

T5 needs real (or silent) audio frames from the simulator. If the
simulator yields no input device, T5 asserts the connection only and says
so in its name; T2 already covers the decision.

### 6.2 Device check (Olof)

1. On the build with W1–W2: tap the mic on a **local** gateway chat; expect
   the iOS prompt once, then text.
2. The same on **byskebox** selected as the gateway.
3. A peer chat through the dashboard's Instances switcher.
4. iOS keyboard dictation in the composer (H3).
5. Background the app mid-recording, return: no crash, recording stopped.
Pull Settings → Diagnostics → Logs afterwards; the grant lines are there.

## 7. Acceptance criteria

- T0–T5 pass, each shown to fail as listed.
- On the device: steps 1–5 complete with no crash and no `.ips`, and
  Diagnostics shows `webContentTerminations` unchanged.
- The crash in issue #9 is explained by a named hypothesis in §1.3, with the
  `.ips` line quoted in §9.

## 8. Open questions and owner actions

1. **The crash log** (Olof, tonight): `xcrun devicectl device info files
   --domain-type systemCrashLogs` for `Latchkey-2026-10-07-15*`,
   `com.apple.WebKit.*-2026-10-07-15*` and `JetsamEvent-2026-10-07-15*`; and
   which mic he tapped, the composer's button or the keyboard's.
2. **App Privacy:** agree that dashboard audio to his own gateway is "not
   collected" (W6)?

Risks: WebKit's AudioWorklet on iOS may be the crash itself (H2), in which
case W1–W2 make the button reach the crash rather than avoid it; the
`MediaRecorder` fallback path is the dashboard's, not ours to force. A
granted mic is a new capability for any script on the gateway's origin; the
grant is scoped to the origin the owner chose, as F6 already trusts it.

## 9. Log

2026-10-07: designed before the crash log; §1.3–1.4 pending it.
2026-10-07: crash log: EXC_CRASH (SIGABRT), termination namespace TCC,
frame `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, "NSMicrophoneUsageDescription"
missing. H1, our process (§1.4 row 1).
2026-10-07: built W1-W3. T0 (21 host checks) and T1-T4 pass; T1 failed on
the pre-W1 build, T2 on a build without the delegate (the page never
reports), T3 on a type-only policy (the subframe got the mic). The
other-origin frame of T3 cannot load under F6, so it is T0's. T5 (session
suite, real bundle) not built. Device check (§6.2) owed.
