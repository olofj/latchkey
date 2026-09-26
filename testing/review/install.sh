#!/bin/sh
# Install or update F19's review gateway on a Linux VM that is already on
# the review tailnet (docs/REVIEW-GATEWAY.md). Run from a checkout, as root:
#
#   sudo testing/review/install.sh [--until YYYY-MM-DD] [--new-token]
#
#   --until      the demo token's last day (UTC), at most 90 days out.
#                Default: kept from the last install, else today + 89 days.
#   --new-token  mint a new demo token (the old one stops working).
#
# Idempotent: re-running it updates the files and the units, and keeps the
# token and date unless told otherwise. It never publishes anything outside
# the tailnet (serve, not funnel).
#
# The gateway is socket-activated: latchkey-review-gateway.socket holds
# 127.0.0.1:8444 and the service starts on the first connection, then stays
# up. This script's own check through serve is such a connection, so it
# stops the service afterwards: it leaves nothing running until a reviewer
# (or the owner's step-4 check) connects.
set -eu

UNTIL=""
NEW_TOKEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --until) UNTIL="$2"; shift 2 ;;
        --new-token) NEW_TOKEN=1; shift ;;
        *) echo "usage: $0 [--until YYYY-MM-DD] [--new-token]" >&2; exit 2 ;;
    esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
HARNESS="$HERE/../harness"
OPT=/opt/latchkey-review
ETC=/etc/latchkey-review
ENV="$ETC/env"
UNIT=latchkey-review-gateway.service
SOCKET=latchkey-review-gateway.socket

die() { echo "error: $*" >&2; exit 1; }
say() { echo "::: $*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
command -v systemctl >/dev/null || die "systemd is needed"
command -v python3 >/dev/null || die "python3 is needed (apt install python3)"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "python3 3.9 or newer is needed"
command -v openssl >/dev/null || die "openssl is needed (apt install openssl)"
command -v tailscale >/dev/null || die "tailscale is needed: curl -fsSL https://tailscale.com/install.sh | sh"

# -- the node: on the tailnet, tagged, with a MagicDNS name ------------------
STATUS=$(tailscale status --json) || die "tailscale is not running (systemctl start tailscaled; tailscale up ...)"
eval "$(printf '%s' "$STATUS" | python3 -c '
import json, sys
s = json.load(sys.stdin)
me = s.get("Self") or {}
print("STATE=%s" % s.get("BackendState", ""))
print("GATEWAY_HOST=%s" % (me.get("DNSName") or "").rstrip(".").lower())
print("TAGS=%s" % ",".join(me.get("Tags") or []))
')"
[ "$STATE" = "Running" ] || die "tailscale is $STATE, not Running (tailscale up --advertise-tags=tag:demo --hostname=demo)"
[ -n "$GATEWAY_HOST" ] || die "no MagicDNS name: turn MagicDNS on in the review tailnet's DNS settings"
case "$GATEWAY_HOST" in *.ts.net) ;; *) die "$GATEWAY_HOST is not a ts.net name";; esac
[ -n "$TAGS" ] || die "this node is not tagged. Latchkey lists another user's node only if it is tagged:
    tailscale up --advertise-tags=tag:demo --hostname=demo   (tagOwners must allow it)"
say "node $GATEWAY_HOST, tags $TAGS"

# -- the files ----------------------------------------------------------------
id latchkey-review >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin latchkey-review
install -d -m 0755 "$OPT" "$OPT/.cache"
install -m 0644 "$HARNESS/fake_gateway.py" "$HARNESS/tls_accept.py" "$HERE/demo_content.json" \
    "$HERE/review_check.py" "$OPT/"
say "fetching the pinned KiroCrew 0.7.1 wheel (sha256-checked; read in place, never installed or run)"
python3 "$OPT/fake_gateway.py" --fetch
python3 "$OPT/fake_gateway.py" --check-bundle --dist "$OPT/.cache/kirocrew-0.7.1-py3-none-any.whl"
chmod 0644 "$OPT"/.cache/*.whl

# -- a loopback certificate: only tailscale serve ever sees it ----------------
install -d -m 0750 -g latchkey-review "$ETC"
if [ ! -s "$ETC/loopback.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost \
        -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \
        -keyout "$ETC/loopback.key" -out "$ETC/loopback.pem" 2>/dev/null
fi
chown root:latchkey-review "$ETC/loopback.key" "$ETC/loopback.pem"
chmod 0640 "$ETC/loopback.key"; chmod 0644 "$ETC/loopback.pem"

# -- the demo token and its date -----------------------------------------------
TOKEN=""; OLD_UNTIL=""
if [ -s "$ENV" ]; then
    TOKEN=$(sed -n 's/^FAKE_GATEWAY_DEMO_TOKEN=//p' "$ENV")
    OLD_UNTIL=$(sed -n 's/^DEMO_UNTIL=//p' "$ENV")
fi
[ "$NEW_TOKEN" -eq 1 ] || [ -z "$TOKEN" ] && TOKEN=$(python3 "$OPT/fake_gateway.py" --new-demo-token)
[ -n "$UNTIL" ] || UNTIL="$OLD_UNTIL"
[ -n "$UNTIL" ] || UNTIL=$(python3 -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=89))')
# The fake's own check: a bad or too-distant date fails here, not at 3 am.
python3 -c "import sys; sys.path.insert(0, '$OPT'); import fake_gateway as f; f.parse_demo_until('$UNTIL')"
umask 077
cat > "$ENV.new" <<EOF
GATEWAY_HOST=$GATEWAY_HOST
DEMO_UNTIL=$UNTIL
FAKE_GATEWAY_DEMO_TOKEN=$TOKEN
EOF
mv "$ENV.new" "$ENV"
umask 022

# -- the units: a socket that starts the service on the first connection -----------
# Stop the service (it may be an earlier install's, bound to 8444 itself) and
# disable it: only the socket is enabled, so the service never starts at boot.
systemctl stop "$UNIT" "$SOCKET" 2>/dev/null || true
systemctl disable "$UNIT" >/dev/null 2>&1 || true
install -m 0644 "$HERE/$UNIT" "$HERE/$SOCKET" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now "$SOCKET" >/dev/null 2>&1 || { journalctl -u "$SOCKET" -n 20 --no-pager >&2; die "the socket did not start"; }
systemctl is-active --quiet "$SOCKET" || die "$SOCKET is not listening"
systemctl is-active --quiet "$UNIT" && die "$UNIT is running before anything connected"
say "socket listening on 127.0.0.1:8444; the gateway starts on the first connection"

# -- on the tailnet, HTTPS with a ts.net certificate ----------------------------------
tailscale serve --bg --https=443 https+insecure://127.0.0.1:8444 \
    || die "tailscale serve failed: turn on HTTPS certificates in the review tailnet's DNS settings"
tailscale funnel status 2>/dev/null | grep -qi "funnel on" && die "funnel is on: this must stay inside the tailnet (tailscale funnel reset)"

# -- the check, through serve ---------------------------------------------------------
say "checking https://$GATEWAY_HOST the way Latchkey does (the first certificate can take a minute)"
ok=0
for i in 1 2 3 4 5 6; do
    if REVIEW_DEMO_TOKEN_FILE="$ENV" python3 "$OPT/review_check.py" "$GATEWAY_HOST"; then ok=1; break; fi
    sleep 10
done
[ $ok -eq 1 ] || echo "warning: the check failed from this node. Run it from another node on the review tailnet before relying on it:
    REVIEW_DEMO_TOKEN=<token> python3 testing/review/review_check.py $GATEWAY_HOST" >&2
if [ $ok -eq 1 ]; then
    systemctl is-active --quiet "$UNIT" || die "the check passed but $UNIT is not running: what answered it?"
    say "the first connection started $UNIT"
fi
# Back to idle: the next connection starts it again.
systemctl stop "$UNIT"
systemctl is-active --quiet "$SOCKET" || die "$SOCKET stopped with the service"
say "stopped $UNIT again; nothing runs until the next connection"

echo
echo "For F19 §6.2 (docs/REVIEW-GATEWAY.md, step 6):"
echo "  GATEWAY_HOST       $GATEWAY_HOST"
echo "  DEMO_TOKEN         $TOKEN"
echo "  TOKEN_VALID_UNTIL  $UNTIL (through the end of that day, UTC)"
