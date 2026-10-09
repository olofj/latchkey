# F25 — Mute the dashboard's notification chirps

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-10-09, by Olof: "I noticed the app now plays the attention chirps/notification sounds. I don't think I want them on my phone all the time, and they interrupt background playing of music or podcasts. Can you add a mute icon next to settings at the top, perhaps? And make it muted by default. I think an explicit request to speak a section back to me is not expected to honor that mute setting; that's just for the chirps." |
| **Touches** | App/Browser (app bar, page scripts), L1 harness |

## 1. Why

Since the #10 fix (`2b8d436a4`) the page's audio session type is `playback`,
so web audio is no longer muted by the silent switch. That made read-aloud
work, and it also made the dashboard's notification chirps audible. Because
`playback` doesn't mix with other audio, each chirp interrupts music or a
podcast.

The chirps are the dashboard's own Web Audio oscillator tones
(`useNotificationSound-*.js`: `AudioContext` + `createOscillator`). They are
controlled per browser by `localStorage["mc-notification-sound"]`
(`{enabled, volume, perCategory}`, default `enabled: true`). The dashboard
re-reads that key when `window` receives `mc-notification-sound-changed`, or
when a `storage` event fires for it.

Read-aloud is a separate path: `new Audio(blobURL).play()` in `App-*.js`. It
doesn't read that key.

## 2. What the owner sees

- A speaker icon next to the settings gear in the app bar (F15's
  summoned bar). It is crossed out (muted) by default, including on first
  launch after this update.
- While muted, no chirps play. Music and podcasts keep playing through
  notifications.
- Tapping the icon unmutes. Chirps play again, at the dashboard's own
  volume and per-category choices. Tapping again mutes. The choice survives
  relaunches and applies to every gateway.
- Read-aloud ("Speak") always plays, muted or not.

Failing: if the dashboard renames the key or the event, the icon still
toggles but chirps play anyway. §5 makes this visible in a test against the
pinned bundle and in the Diagnostics log.

## 3. Non-goals

- No change to the desktop dashboard. The key is per-browser localStorage,
  so muting the phone doesn't mute the desktop.
- No per-category control in Latchkey; the dashboard's own Settings keep it.
- No change to read-aloud or to the `playback` session it needs. Making
  chirps mix with other audio (`ambient`) when unmuted is a possible
  follow-up, not part of this.

## 4. Design

- `App/Browser/ChirpMute.swift`: `@AppStorage("chirpsMuted")`, default
  `true`. It is the source of truth.
- App bar (`App/Browser/AppBar.swift`): a `speaker.slash` / `speaker.wave.2`
  button left of the gear. Accessibility label "Mute notification sounds" or
  "Unmute notification sounds". Identifier `appbar.mute`.
- Page script (`PageScriptSources.chirpMute`, main frame, document start,
  gateway origin only per F6):
  - read `localStorage["mc-notification-sound"]`, keep `volume` and
    `perCategory`, and set `enabled` to `!muted`
  - write it back and dispatch `mc-notification-sound-changed`
  - inject the muted state per load (as the user script's source, or through
    a small bridge), so it is applied before the dashboard's first read
- On toggle: `evaluateJavaScript` the same apply function in the live page,
  so no reload is needed.
- If the dashboard's own Settings sound toggle is used on the phone,
  Latchkey's state wins on the next load. Recorded as a known overlap in
  DECISIONS.
- Log line: `chirp-mute: muted|unmuted (applied|no-key)`.

## 5. Tests

- L1, fake dashboard page `chirps`: a stub of the sound module that reads
  the key and listens for the event, and reports `enabled`.
  1. Assert muted on first launch.
  2. Tap `appbar.mute`, assert unmuted live, without a reload.
  3. Relaunch and assert the state persisted.
  4. Assert a read-aloud play (F23's `speak` page) still plays while muted.
- Show it can fail: with the page script disabled, test 1 reads
  `enabled: true`.
- Check that the key and event names still exist in the pinned bundle,
  e.g. a host check that greps the 0.7.1 wheel's `useNotificationSound-*.js`
  for `mc-notification-sound` and `mc-notification-sound-changed`.

## 6. Device check

1. On the new build, music plays and a turn finishes: no chirp, no pause.
2. Tap unmute: the next notification chirps.
3. Muted, tap Speak on a reply: it is heard.
