// Host tests for the -TestControlURL override (R17). Built twice by
// test-control-plane.sh: with LATCHKEY_TEST_HOOKS (the Testing configuration) and
// without it (every build that can reach a phone).
import Foundation

let args = CommandLine.arguments
if args.count > 1, args[1] == "print" {
    print(TestControlPlane.controlURLOverride() ?? "<nil>")
    exit(0)
}

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("  ok   \(what)") } else { print("  FAIL \(what)"); failures += 1 }
}

print("TestControlPlane.isLoopback")
for h in ["127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", "::1", "[::1]"] {
    check(TestControlPlane.isLoopback(h), "\(h) is loopback")
}
for h in ["128.0.0.1", "127.0.0.1.example.com", "127.0.0", "127.0.0.256", "127..0.1",
          "example.com", "controlplane.tailscale.com", "100.64.0.1", "::2", "", "localhost.evil.com"] {
    check(!TestControlPlane.isLoopback(h), "\(h.isEmpty ? "<empty>" : h) is not loopback")
}
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all passed")
