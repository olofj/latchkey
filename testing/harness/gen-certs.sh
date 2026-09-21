#!/usr/bin/env bash
# Mint the test CA and leaf certificate the offline harness serves TLS with.
#
# Idempotent: regenerates only when something is missing or --force is passed.
# Everything it writes is gitignored.
#
# Two things iOS is strict about, both already encoded in ca.cnf / leaf.cnf and
# repeated here because they are the failures people hit:
#
#   * The CA MUST carry `keyUsage=critical,keyCertSign,cRLSign`. Without it,
#     iOS rejects the whole chain with "CA cert does not include key usage
#     extension" — which reads like a trust-store problem and is not.
#   * The leaf MUST carry `subjectAltName`. iOS ignores CN entirely, so a
#     certificate that openssl and curl are perfectly happy with still fails on
#     device with a generic handshake error.
#
# Outputs (all in this directory):
#   ca.key, ca.pem      the test root
#   ca.der              the same root in DER, for `simctl keychain add-root-cert`
#   server.key          the leaf's private key
#   server.pem          leaf + CA, in that order, for dashboard.py
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ $FORCE -eq 0 && -f ca.pem && -f ca.der && -f server.pem && -f server.key ]]; then
    # Regenerate anyway if the leaf has expired or expires within a day —
    # a silently expired fixture produces a TLS error that looks like a
    # proxy bug and costs an hour.
    if openssl x509 -checkend 86400 -noout -in server.pem >/dev/null 2>&1; then
        echo "certs present and valid; use --force to regenerate"
        exit 0
    fi
    echo "leaf certificate has expired or is about to; regenerating"
fi

echo "==> test root CA"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout ca.key -out ca.pem \
    -days 3650 -config ca.cnf >/dev/null 2>&1
openssl x509 -in ca.pem -outform der -out ca.der

echo "==> leaf for dash.tail-scale.ts.net / dash.localtest.me / localhost / 127.0.0.1 / ::1"
openssl req -newkey rsa:2048 -nodes \
    -keyout server.key -out server.csr \
    -subj "/CN=dash.tail-scale.ts.net" >/dev/null 2>&1
openssl x509 -req -in server.csr \
    -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out leaf.pem -days 825 \
    -extfile leaf.cnf -extensions ext >/dev/null 2>&1

# dashboard.py hands this straight to `SSLContext.load_cert_chain`, which wants
# the leaf first and the issuer after it.
cat leaf.pem ca.pem > server.pem
rm -f server.csr leaf.pem

echo "==> verifying"
openssl verify -CAfile ca.pem server.pem >/dev/null
# Fail loudly here rather than inside a simulator, where the same mistake
# surfaces as an opaque -1200 and no explanation.
openssl x509 -in ca.pem -noout -text | grep -q "Certificate Sign" \
    || { echo "error: CA is missing keyCertSign — iOS will reject it" >&2; exit 1; }
openssl x509 -in server.pem -noout -text | grep -q "DNS:dash.tail-scale.ts.net" \
    || { echo "error: leaf is missing subjectAltName — iOS ignores CN" >&2; exit 1; }
openssl x509 -in server.pem -noout -text | grep -q "DNS:dash.localtest.me" \
    || { echo "error: leaf is missing dash.localtest.me — the anti-leak test (R10) needs it" >&2; exit 1; }

echo "ok: ca.pem, ca.der, server.pem, server.key"
echo
echo "Trust the CA in a booted simulator with:"
echo "    xcrun simctl keychain booted add-root-cert $(pwd)/ca.der"
