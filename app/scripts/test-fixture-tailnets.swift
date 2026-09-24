// Host tests for FixtureTailnets.foreign (R10's allow-list).
//
// The bug this exists to prevent: the label was once found by splitting the
// text on ".", which reads back across JSON punctuation when the preceding
// document contains no dot. Every legitimate fixture then looked foreign and
// the app died on launch in three suites. Case 1 below is that exact input.
import Foundation

var failures = 0
func expect(_ got: String?, _ want: String?, _ what: String) {
    if got == want { return }
    print("  FAIL: \(what): got \(got ?? "nil"), want \(want ?? "nil")")
    failures += 1
}

// 1. The real L1 fixture, verbatim in shape: sortedKeys JSON whose text before
//    the tailnet name contains no "." at all.
let realFixture = #"{"BackendState":"Running","CurrentTailnet":{"MagicDNSEnabled":true,"MagicDNSSuffix":"tail-scale.ts.net","Name":"tail-scale.ts.net"},"Peer":{"nodekey:fixture-dash":{"DNSName":"dash.tail-scale.ts.net.","HostName":"dash","Online":true}},"Self":{"DNSName":"latchkey-iphone.tail-scale.ts.net.","HostName":"latchkey-iphone"},"Version":"fixture"}"#
expect(FixtureTailnets.foreign(in: realFixture), nil, "the real L1 fixture is accepted")

// 2. Both allow-listed tailnets, bare and as a suffix.
expect(FixtureTailnets.foreign(in: "tail-scale.ts.net"), nil, "bare fixture tailnet")
expect(FixtureTailnets.foreign(in: "gw.example.ts.net"), nil, "example.ts.net as a suffix")
expect(FixtureTailnets.foreign(in: #"{"a":true,"s":"example.ts.net"}"#), nil,
       "allowed name with no preceding dot")

// 3. A real tailnet is caught wherever it sits.
expect(FixtureTailnets.foreign(in: #"{"DNSName":"gw.some-real-net.ts.net."}"#),
       "some-real-net.ts.net", "a non-fixture tailnet is caught")
expect(FixtureTailnets.foreign(in: "some-real-net.ts.net"), "some-real-net.ts.net",
       "caught when bare")
expect(FixtureTailnets.foreign(in: #"{"a":"dash.tail-scale.ts.net","b":"x.other.ts.net"}"#),
       "other.ts.net", "caught after an allowed name")

// 4. Case folding: a fixture must not slip through by shouting.
expect(FixtureTailnets.foreign(in: "MIXED.Tail-Scale.TS.NET"), nil, "allowed, case-insensitive")
expect(FixtureTailnets.foreign(in: "GW.Some-Real-Net.TS.NET"), "some-real-net.ts.net",
       "caught, case-insensitive")

// 5. Nothing to find.
expect(FixtureTailnets.foreign(in: ""), nil, "empty string")
expect(FixtureTailnets.foreign(in: "no tailnet here"), nil, "no tailnet at all")
expect(FixtureTailnets.foreign(in: "localtest.me and 127.0.0.1"), nil, "non-tailnet hosts")

// 6. Degenerate: a bare ".ts.net" has no label, so there is nothing to report.
expect(FixtureTailnets.foreign(in: ".ts.net"), nil, "no label before the suffix")

if failures == 0 {
    print("14/14 fixture tailnet checks passed")
} else {
    print("\(failures) of 14 fixture tailnet checks FAILED")
    exit(1)
}
