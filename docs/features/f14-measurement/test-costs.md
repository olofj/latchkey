# F14 — what each UI test costs and what it alone asserts (2026-09-26)

The input to the pruning pass logged in `F14-fast-suites.md` §9 (2026-09-26).
Seconds are measured, not estimated: L1 from `scripts/l1-durations.txt`,
session from `scripts/session-durations.txt`, discovery from
`app/build/discovery-logs/20260925-173415`, lifecycle from
`app/build/lifecycle-logs/20260925-180207`. Launches count `app.launch()`
calls, relaunches included; a launch plus terminate is ~6-7 s of the figure.

Lever: **S** shares a launch with another test that only reads the same
setup; **W** waits that only ever time out, or XCTest's ~1 s polling; **H**
the claim is logic a host test could hold; **P** proposed to the owner, not
done; **K** kept as is (the reason is in the guard column).

Owner-reported bugs and where they are guarded: keyboard blanking the
dashboard (L1 `testTypingInThePageKeepsItOnScreen`, session
`testASharedLinkReachesTheChosenSession`); page under the Dynamic Island (L1
`testInsetProbesReportWhatThePageIsTold`); the share posting twice (session
`testLaterAfterThePostLeft…` and its control `testLaterBeforeThePostLeft…`);
the picker stalling (discovery `testAStalledLoopback…` ×2, lifecycle
`testAStalledLoopbackUnderALivePageIsRecovered`).

| s | suite | test | L | what it alone asserts | guards | lever |
|---|---|---|---|---|---|---|
| 55.3 | session | testThePageRefreshesAcrossExpiriesWithoutTheSheet | 1 | ≥5 rotations in a 40 s watch, no sheet | R20/R25 | K: the watch is the claim |
| 47.2 | session | testSigningOutRevokesTheSessionHereAndAtTheGateway | 3 | logout + revoke at the gateway; cookies gone from disk | R32 | W |
| 46.5 | session | testTheShareSheetSavesForTheAppAndTheAppSendsIt | 1+Safari | the extension saves, the app sends | F3 stage 2 | K |
| 43.2 | session | testSigningOutWithTheGatewayUnreachableClearsThisDeviceAndSaysSo | 2 | "this device only"; the local clear has teeth | R32 review | W |
| 41.3 | lifecycle | testResumeAfterAThirtySecondFreeze… | 1 | nothing while frozen; same document, refetch, WS open | M6.5 | K: 30 s freeze is the claim |
| 39.4 | session | testResetAppEndsTheSessionAndStartsOver | 1 | logout + revoke, back to first run | R32/M5 | W |
| 38.7 | session | testLaterBeforeThePostLeftKeepsTheItem | 1 | nothing posted, item re-offered | issue #1 control | K, W |
| 38.2 | session | testNetworkLossDoesNotShowTheSheet | 1 | no sheet across a 20 s blackhole | M4 | K |
| 38.1 | L1 | testStalledLoadShowsTheConnectingStateForItsWholeDuration | 1 | connecting timeline, 8 s hint, cause, ≤3 dials | F4, pins showDelay/hint | K: pinned timing |
| 37.5 | session | testLaterAfterThePostLeftIsRecordedNotReoffered | 1 | recorded, not re-offered | **issue #1, owner** | K, W |
| 36.9 | discovery | testSearchAgainContinuesFromWhereItStopped | 1 | count climbs per tap to the total | F7 §4.3 | S (absorbs Truncated) |
| 36.4 | session | testSwitchingBackToAGatewayNeedsNoNewSignIn | 1 | no second redemption | F5 §7 | W |
| 36.3 | lifecycle | testDefunctRelayListenerIsRestartedByAFailedPageLoad | 1 | 6 s blind poll; a tap restarts the relay | R30 | K |
| 36.0 | L1 | testANodeThatCannotStartShowsAScreenInsteadOfDying | 1 | G7, app alive, retries stop after five | F8 | P: 26 s of it is waiting out the real backoff |
| 35.2 | discovery | testTheSwitcherListsTheCurrentGatewayAndSwitchesToAnother | 2 | current row; answers ≤5 s; switch; relaunch keeps list | F5 §7, R39 | W |
| 34.8 | session | testUnreachableIsKeptAndRetried | 1 | kept, then Retry sends | F3 | W |
| 34.2 | session | testOverTheLimitIsRefusedAtCaptureAndA413IsShown | 2 | refused at capture; 413 words | F3, `share_refused` log control | K, W |
| 31.4 | lifecycle | testAStalledLoopbackUnderALivePageIsRecovered | 1 | two strikes → recovered under a live page | **F16, owner** | K |
| 30.8 | session | testACLISessionSurvivesAGatewayRestart | 1 | WS reconnects, keeps rotating | R24 | W |
| 30.3 | discovery | testDeviceCheckRehearsalPurgatoryThenAddressMove | 1 | "4 didn't answer"; the address move | DEVICE-CHECK | W |
| 29.9 | L1 | testTheAppBarRetractsOnADeliberateScrollAndComesBack | 2 | bar retracts/returns; VoiceOver keeps it | F15 | K (P: share with typing) |
| 28.7 | L1 | testTypingInThePageKeepsItOnScreen | 2 | keyboard up: page ends at it, not black | **owner bug 09-24** | K |
| 28.0 | session | testASharedLinkReachesTheChosenSession | 1 | post body; frame unchanged after the keyboard | F3, **F13 owner** | K, W |
| 27.3 | L1 | testInsetProbesReportWhatThePageIsTold | 3 | top inset 0, below the bar, bottom gap | F9/F13/F15, **Dynamic Island owner** | K |
| 26.8 | session | testAColdLaunchKeepsTheItem | 2 | inbox is on disk | F3 | K, W |
| 26.2 | L1 | testStatusNamesTheCommitTheAppWasBuiltFrom | 1 | Status shows a 12-hex commit | F12 | K (P: live chain) |
| 26.2 | session | testSignedOutMidShareThenResumed | 1 | waits for sign-in, then sends | F3 | W |
| 25.5 | session | testTheLastSessionIsPreselected | 1 | preselect survives | F3 | W |
| 25.3 | L1 | testStrictModeBlocksTheAllowlistedCDNs | 1 | strict: esm.sh and away 0 | F6 §4.1a | K (P: live chain) |
| 25.0 | session | testOnlyAListedSlotIsEverPosted | 1 | nothing selected, 0 violations | F3 §4.5 | W |
| 24.9 | session | testPastingCLIOutputSignsIn | 1 | one redemption, clipboard cleared, expiry shown | M4.4/R23 | **S** (signed-in group) |
| 24.8 | session | testSignedOutShowsTheNativeSheetAndHidesThePageBanner | 1 | sheet; banner hidden past the watchdog | R22/R23 | W |
| 24.8 | L1 | testNothingOfOursSitsOnThePageAndSettingsIsReachable | 1 | nothing overlaps the page; gear both ways | F15 §6 | K |
| 24.4 | discovery | testTheChosenGatewayPersistsAcrossRelaunch | 2 | no sweep on relaunch; first request GET / | M5 | **S** (with FirstRun) |
| 23.8 | session | testARefusedPostOffersPrefill | 1 | prefill; item kept | F1/F3 | W |
| 23.0 | discovery | testAStalledLoopbackIsReplacedAndTheSearchThenFindsTheGateway | 1 | recovered ≤25 s, then found | **F16, owner** | **S** (with Ends) |
| 23.0 | session | testABusySlotIsQueuedNotSent | 1 | "queued", inbox 0 | F3 | P: delete (host-covered) |
| 21.7 | session | testALostRefreshAtARestartEndsInTheSheet | 1 | violation, then sheet | M4 review | W |
| 21.5 | session | testADocumentIsUploadedThenReferenced | 1 | upload, then `[attached_file 1]` | F3, D1, `share_uploaded` | K, W |
| 21.4 | session | testARevokedChainShowsTheSheetAndANewTokenRecovers | 1 | reload, sheet, recovery | R21 | W |
| 21.2 | discovery | testAPeerSkippedForItsOSIsOfferedAndCanBeProbed | 1 | "1 not checked", "OS synology", probe | F7 §4.4 | W |
| 21.0 | discovery | testManualEntryWhenNoGatewayIsFound | 1 | none state; re-probe; public refused; `dash` expanded | M5 | P (absorb Finished) |
| 20.1 | session | testFiftyMegabytesGoThroughByteForByte | 1 | byte for byte, no content-process death | F3 §7a | K |
| 19.5 | discovery | testAKnownGatewayThatDoesNotAnswerIsLabelledAndF4ShowsIt | 1 | "not answering"; F4 overlay | F5 §7, F4 | P (absorb OffTheTailnet) |
| 19.4 | session | testALostRefreshResponseIsRecoveredByTheGraceWindow | 1 | grace re-serve | R25 | W |
| 19.4 | session | testAnUnsupportedTypeShowsTheGatewaysWords | 1 | 400 words shown | F3 | P: delete (covered by 413 test + host) |
| 19.3 | discovery | testATruncatedSweepSaysSoAndCountsOnlyWhatItProbed | 1 | "ran out of time"; probed < total | F7 §4.1 | P (fold into SearchAgain) |
| 18.8 | lifecycle | testDefunctLoopbackListenerIsReplacedAndNewConnectionsGetThrough | 1 | recovered; new connection works | M6.7/R14 | K |
| 18.3 | lifecycle | testResumeAfterASevenSecondFreeze… | 1 | same as 30 s, lock/unlock shape | M6.5 | K |
| 18.1 | L1 | testStartingANewNodeMovesTheOldStateAsideAndKeepsIt | 2 | old state set aside intact | F8, lost data | K |
| 18.1 | session | testTheSessionsPanelStillOpensInPortrait | 1 | panel search and New hittable | F5 §1 | **S** (signed-in group) |
| 18.0 | session | testWithoutTheRuleListTheRealDashboardReachesForGoogle | 1 | reaches Google | F6 control | K |
| 17.9 | session | testTheRealDashboardConnectsToNothingButTheGateway | 1 | connect set = {gw:443} | F6 §6/R41, fonts log control | K |
| 17.9 | session | testAFreshSeedIsInTheInbox | 1 | a 6-day seed stays | F3 control | P: delete |
| 17.7 | session | testABadTokenSaysSoAndKeepsTheSheet | 1 | failure message, 0 redemptions | R23 | W |
| 17.7 | session | testSignOutEverywhereShowsTheSheet | 1 | sheet via the 403 interceptor | M4 review | W |
| 17.6 | L1 | testTheErrorPageOffersRetryAndAnotherGateway | 2 | Try again reloads; Choose gateway | F4/M8 | K (P: one launch) |
| 17.5 | L1 | testATappedLinkToAnotherAppAsksFirst | 1 | tapped maps: asks; Cancel/Open | F17/R42 | K |
| 17.5 | session | testABrokenBridgeLeavesThePageBannerVisible | 1 | banner fallback visible | R22 control | K |
| 17.4 | L1 | testLoggingSetupFailureStopsTheNodeRatherThanStartingItBlind | 1 | zero traffic before/after Try now | F8 §4.6 | K: absence windows |
| 17.0 | discovery | testAKnownGatewayOffTheTailnetCannotBeChosen | 1 | row disabled; a tap does nothing | F5 §7 | P (fold into NotAnswering) |
| 17.0 | session | testAnExpiredSessionIsRecoveredByThePagesInterceptor | 1 | 403 → silent refresh | R20 | W |
| 16.9 | L1 | testBlockedImageShowsAMarkerThatOpensSafari | 1 | markers; 44 pt; tap opens Safari | F6 §4a | K (P: live chain) |
| 16.6 | L1 | testAnUntappedLinkAwayAsksOnlyOnce | 1 | asks once, then silent | F17 | K |
| 16.6 | lifecycle | testShutDownTCPSocketsAreSurvivedAndThePageReconnects | 1 | app survives; page reconnects | M6.7, crash | K |
| 16.5 | L1 | testAnUnwritableStateDirectoryIsSurvived | 2 | a real permission failure → G7 | F8, crash | K |
| 16.4 | session | testTheInstanceChipsStayInOneRowInLandscape | 1 | one row in landscape | F5/F9 | **S** (signed-in group) |
| 16.2 | discovery | testAGatewayOwnedByAnotherUserIsOffered | 1 | reason "another owner"; probe anyway | F7 §4.4 | P: delete |
| 15.4 | session | testTheSweepRunsAtLaunch | 1 | an 8-day item is swept | F3, `share_swept` control | K |
| 15.1 | discovery | testFindFromTheUnreachableBannerSwitchesGateway | 1 | banner Find sweeps afresh | M5.5 | W |
| 15.0 | discovery | testFirstRunFindsExactlyTheGatewayAndLoadsIt | 1 | auto-choose gw; probe order | M5/R26 | **S** (with Persists) |
| 14.8 | discovery | testAFinishedSweepSaysItCheckedThemAll | 1 | no "ran out"; probed = total | F7 §4.2 | P (fold into ManualEntry) |
| 14.6 | session | testTheInstanceChipsDoNotOverlapInPortrait | 1 | chips disjoint, hittable | F5 §1a | **S** (signed-in group) |
| 14.5 | L1 | testTryNowRestartsTheNodeImmediately | 1 | Try now → dashboard <5 s | F8 | K |
| 14.5 | L1 | testWindowOpenToAnotherOriginStillOpensSafari | 1 | window.open → Safari | F6/F17 | K (P: live chain) |
| 14.3 | discovery | testAStalledLoopbackEndsTheSearchWithinSeconds | 1 | P6 within 16 s; 0/4 answered | **F16, owner** | **S** (with Replaced) |
| 14.2 | L1 | testAScriptCannotOpenAnotherAppWithoutATap | 1 | untapped opens nothing | F17 | K |
| 13.8 | session | testAQRSessionEndsAtAGatewayRestart | 1 | sheet at a restart | R24 | W |
| 13.3 | L1 | testAReturningUserIsNotReintroduced | 2 | no intro when returning | F11 | K |
| 13.0 | L1 | testAnAllowlistedCDNIsFetchedAndItsLookalikesAreNot | shared | esm.sh yes, lookalikes no | F6 §4.1a | S (pays the F6 run) |
| 12.9 | L1 | testWithoutTheRuleListTheAwayOriginIsReached | 1 | positive control | F6 §6 | K |
| 12.7 | L1 | testRedirectToAnotherOriginLeavesTheAppAndKeepsTheDashboard | 1 | redirect → Safari | R3 | K |
| 12.2 | L1 | testSignInTokenIsStrippedFromTheAddress | 1 | token stripped from location | R2, R1 log grep | K |
| 11.8 | L1 | testFailedRuleCompileLoadsNothing | 1 | filter named; 0 traffic | F6 §2 | K |
| 10.5 | L1 | testTheNodeStartRetryIsVisibleAndSucceeds | 1 | an untapped retry reaches the dashboard | F8 | K |
| 9.8 | L1 | testAFastLoadDoesNotLeaveTheConnectingStateOnScreen | 1 | nothing left on screen after commit | F4, pins showDelay | **S** (default run) |
| 9.7 | L1 | testAGatewayAnswering502ShowsTheErrorPageInsteadOfABlankScreen | 1 | 502 → error page | F4 D10 | K |
| 9.7 | L1 | testATapThatNavigatesByScriptStillOpensSafari | 1 | tap+script → Safari, no prompt | F17 §4.2 | K |
| 9.0 | L1 | testDashboardLoadsThroughTheProxy | 1 | WS echo, SSE, CONNECT | M2.5 | **S** (default run) |
| 9.0 | L1 | testProxyGoneFailsWithoutDirectFallback | 1 | -1009 via relay, 0 requests | R10 | K |
| 8.4 | L1 | testProxyGoneWithoutRelayFailsWithoutDirectFallback | 1 | -1004 WebKit direct, 0 requests | R10 | K |
| 8.2 | L1 | testCertificateNameMismatchShowsTheErrorPage | 1 | error names the certificate | M2 | K |
| 8.0 | L1 | testTheGatewaysOwnMachineryStillWorks | 1 | WS, SSE, data:, blob:, srcdoc; no SW | F6 §4.1 | **S** (F6 run) |
| 8.0 | L1 | testBlackholedProxyFailsWithoutDirectFallback | 1 | error page, 0 requests | R10, F16 | K |
| 7.9 | L1 | testNonTailnetOriginLoadsDirectAndNeverTouchesTheProxy | 1 | direct, no CONNECT | R10 control | K |
| 7.9 | L1 | testUnreachableGatewayShowsTheErrorPage | 1 | error; upstream_fail | M2 | K |
| 6.5 | L1 | testTheSignInButtonSurvivesItsOwnCopy | 1 | XXXL: hittable, in safe area | F11 §4.3 | K |
| 6.5 | L1 | testAFirstLaunchExplainsItself | 1 | intro, steps, button label | F11 | **S** (gate run) |
| 6.3 | L1 | testTheIntroductionNamesThePostLoginSteps | 1 | steps name approve + access | F11, owner 09-24 | **S** (gate run) |
| 0.1 | L1 | testOffOriginLoadsNeverReachTheAwayOrigin | shared | 0 req/CONNECT/TLS to away | F6 §6 | S (b4fb2bd) |
| 0.1 | L1 | testTheFontHostsStayBlockedWhileTheCDNsAreAllowed | shared | font hosts 0 | F6 §2 | S (b4fb2bd) |
| 0.1 | L1 | testThePageCannotWidenTheAllowlist | shared | runtime additions never load | F6 §6 | S (b4fb2bd) |
