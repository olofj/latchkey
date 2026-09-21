// Host tests for App/Session/TokenInput.swift (M4.4, R23).
import Foundation

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}
func parsed(_ s: String) -> TokenInput.Parsed? { TokenInput.parse(s) }

let tok = "k1.AbCdEfGh-_.~0123456789"

print("== links")
// `kirocrew token` prints up to three URLs; a multi-line paste is not a URL.
let cli = """
  Dashboard sign-in links (valid 5 minutes):
    http://localhost:5476/?token=\(tok)
    https://kirocrew.example.net/?token=\(tok)
    https://gw.tail-scale.ts.net/?token=\(tok)
"""
expect(parsed(cli) == .init(token: tok, linkHost: "localhost"), "CLI output: the first token, from the first link")
expect(parsed("https://gw.tail-scale.ts.net/?token=\(tok)") == .init(token: tok, linkHost: "gw.tail-scale.ts.net"),
       "a single sign-in URL")
expect(parsed("https://gw.tail-scale.ts.net/chat?sid=1&token=\(tok)&x=2#frag")?.token == tok,
       "other parameters and the fragment are not part of the token")
expect(parsed("<https://gw.tail-scale.ts.net/?token=\(tok)>")?.token == tok, "angle-bracketed link")
expect(parsed("\"https://gw.tail-scale.ts.net/?token=\(tok)\",")?.token == tok, "quoted link with trailing comma")
expect(parsed("see https://evil.example/?token=\(tok) now")?.linkHost == "evil.example",
       "a foreign host is REPORTED (the caller never navigates there)")
expect(parsed("https://gw.tail-scale.ts.net/?token=") == nil, "an empty token is no token")
expect(parsed("https://gw.tail-scale.ts.net/?token=abc<script>x") == nil, "markup in the value is refused")
expect(parsed("https://gw.tail-scale.ts.net/?Token=\(tok)") == nil, "the parameter name is case-sensitive, as the server's is")
expect(parsed("https://gw.tail-scale.ts.net/?tokenx=\(tok)") == nil, "only the token parameter itself")
expect(parsed("https://gw.tail-scale.ts.net/?mytoken=\(tok)") == nil, "not a parameter merely ending in token")

print("== bare tokens")
expect(parsed(tok) == .init(token: tok, linkHost: nil), "a bare token")
expect(parsed("  \n\(tok)\n ") == .init(token: tok, linkHost: nil), "surrounding whitespace is trimmed")
expect(parsed("abc+def/ghi=jkl0123")?.token == "abc%2Bdef%2Fghi%3Djkl0123", "'+', '/' and '=' are encoded")
expect(parsed("abc%2Bdef0123456789")?.token == "abc%2Bdef0123456789", "an already-encoded token is kept")
expect(parsed("short") == nil, "too short to be a token")
expect(parsed("two words here and more") == nil, "a sentence is not a token")
expect(parsed("https://gw.tail-scale.ts.net/") == nil, "a link without a token is not a token")
expect(parsed("") == nil && parsed("   \n") == nil, "nothing")

print("== the sign-in URL")
let gw = URL(string: "https://gw.tail-scale.ts.net")!
expect(TokenInput.signInURL(origin: gw, token: tok)?.absoluteString == "https://gw.tail-scale.ts.net/?token=\(tok)",
       "origin + /?token=")
expect(TokenInput.signInURL(origin: URL(string: "https://gw.tail-scale.ts.net/")!, token: "a")?.absoluteString
       == "https://gw.tail-scale.ts.net/?token=a", "a trailing slash is not doubled")
expect(TokenInput.signInURL(origin: URL(string: "https://127.0.0.1:8444")!, token: "a")?.absoluteString
       == "https://127.0.0.1:8444/?token=a", "a port is kept")

print(failures == 0 ? "\(checks)/\(checks) token input checks passed" : "\(failures) of \(checks) token input checks FAILED")
exit(failures == 0 ? 0 : 1)
