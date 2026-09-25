# Offline test harness: a stub SOCKS5 proxy in front of a fake dashboard.
#
# Runs with no Tailscale account, no tailnet and no network. The point is to
# exercise the WKWebView -> SOCKS5 -> HTTPS -> WebSocket/SSE path -- and the
# anti-leak negative case -- deterministically and in seconds.
#
#   make harness-up      start both, write pidfiles, wait until listening
#   make harness-down    stop both
#   make harness-status  what is running
#   make certs           mint the test CA + leaf (idempotent)
#   make trust           teach the booted simulator to trust the test CA
#   make bundle          fetch the pinned KiroCrew wheel into .cache (verified)
#   make gateway-up      start the fake KiroCrew gateway (real pinned bundle, M4)
#   make gateway-down    stop it
#   make gateway-check   its host-side contract self-test (starts and stops it)
#
# The fake gateway is separate from harness-up on purpose: it refuses to start
# unless its bundle is the pinned one, and a missing or wrong bundle must not
# take the offline (L1) suite down with it.
#
# BLACKHOLE=1 starts the proxy in refuse-every-CONNECT mode, which is the
# negative fixture: the page load must FAIL rather than quietly succeeding by
# some direct route.

PY           ?= python3
PROXY_PORT   ?= 1080
PROXY_CONTROL_PORT ?= 1081
DASH_PORT    ?= 8443
DASH_CONTROL_PORT  ?= 8480
GW_PORT      ?= 8444
GW_CONTROL_PORT ?= 8481
GW_EXPIRE_IN ?= 0
PROXY_USER   ?= tsnet
PROXY_PASS   ?= s3cret
DASH_HOST    ?= dash.tail-scale.ts.net
RUN_DIR      ?= .run
JOURNAL      ?= $(RUN_DIR)/proxy.ndjson
BLACKHOLE    ?= 0

PROXY_PID    := $(RUN_DIR)/socks5.pid
DASH_PID     := $(RUN_DIR)/dashboard.pid
PROXY_LOG    := $(RUN_DIR)/socks5.log
DASH_LOG     := $(RUN_DIR)/dashboard.log
GW_PID       := $(RUN_DIR)/gateway.pid
GW_LOG       := $(RUN_DIR)/gateway.log

# F6 §6: the hosts /single-origin reaches for besides the away origin. Under
# -ProxyEverything each would be SERVED -- and counted by Host -- by the fake
# dashboard if the app's rule list allowed it, and none can reach the real
# host. dash.tail-scale.ts.net:8444 is the port probe (a gateway rule that
# forgot the port); it is a map key, unrelated to GW_PORT's listener.
F6_MAPS := $(foreach hp,dash.tail-scale.ts.net:8444 esm.sh:443 esm.sh.away.example:443 \
             esm.shady.example:443 esm.sh:8444 fonts.googleapis.com:443 fonts.gstatic.com:443, \
             --map $(hp)=127.0.0.1:$(DASH_PORT))

ifeq ($(BLACKHOLE),1)
  BLACKHOLE_FLAG := --blackhole
else
  BLACKHOLE_FLAG :=
endif

.PHONY: certs
certs:  ## Mint the test CA and leaf (no-op if present and unexpired)
	@./gen-certs.sh

.PHONY: trust
trust: certs  ## Trust the test CA in the booted simulator
	@xcrun simctl keychain booted add-root-cert "$(CURDIR)/ca.der"
	@echo "::: test CA trusted in the booted simulator :::"

.PHONY: harness-up
harness-up: certs harness-down  ## Start the fake dashboard + stub proxy
	@mkdir -p $(RUN_DIR)
	@# Refuse to start on top of someone else's listener.
	@#
	@# This is not hypothetical: a dashboard left over from an earlier session
	@# was still holding :$(DASH_PORT), serving a certificate minted before the
	@# current CA. The replacement died instantly on "address already in use",
	@# a port probe saw the STRANGER still listening and reported the harness
	@# healthy, and every TLS check then failed with "unable to get local
	@# issuer certificate" -- which reads like a certificate bug and is not.
	@for port in $(DASH_PORT) $(DASH_CONTROL_PORT) $(PROXY_PORT) $(PROXY_CONTROL_PORT); do \
	    pids=$$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null || true); \
	    if [ -n "$$pids" ]; then \
	        echo "error: 127.0.0.1:$$port is already in use by pid(s): $$pids" >&2; \
	        echo "       These are probably strays from an earlier run." >&2; \
	        echo "       Stop them with: make harness-reap" >&2; \
	        exit 1; \
	    fi; \
	done
	@# Truncate the journal so an assertion can't pass on a previous run's
	@# connect events -- the exact way this kind of test rots into a no-op.
	@: > $(JOURNAL)
	@$(PY) dashboard.py --port $(DASH_PORT) --control-port $(DASH_CONTROL_PORT) \
		--cert server.pem --key server.key > $(DASH_LOG) 2>&1 & echo $$! > $(DASH_PID)
	@$(PY) socks5stub.py --port $(PROXY_PORT) \
		--user $(PROXY_USER) --password $(PROXY_PASS) \
		--journal $(JOURNAL) $(BLACKHOLE_FLAG) --control-port $(PROXY_CONTROL_PORT) \
		--map $(DASH_HOST):443=127.0.0.1:$(DASH_PORT) \
		--map wrong.tail-scale.ts.net:443=127.0.0.1:$(DASH_PORT) \
		--map down.tail-scale.ts.net:443=127.0.0.1:9 \
		--map gw.tail-scale.ts.net:443=127.0.0.1:$(GW_PORT) \
		$(F6_MAPS) \
		> $(PROXY_LOG) 2>&1 & echo $$! > $(PROXY_PID)
	@# Wait for OUR processes to listen. Checking the port alone is what let
	@# the stray above masquerade as a healthy harness, so verify the pid we
	@# started is both alive and the one holding the port.
	@for spec in "$(DASH_PORT):$(DASH_PID):$(DASH_LOG)" "$(PROXY_PORT):$(PROXY_PID):$(PROXY_LOG)"; do \
	    port=$${spec%%:*}; rest=$${spec#*:}; pidfile=$${rest%%:*}; log=$${rest#*:}; \
	    pid=$$(cat $$pidfile); \
	    ok=0; \
	    for i in $$(seq 1 100); do \
	        if ! kill -0 $$pid 2>/dev/null; then \
	            echo "error: harness process (pid $$pid) exited during startup" >&2; \
	            echo "--- $$log ---"; cat $$log 2>/dev/null; exit 1; \
	        fi; \
	        if lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null | grep -qx "$$pid"; then ok=1; break; fi; \
	        sleep 0.1; \
	    done; \
	    if [ $$ok -ne 1 ]; then \
	        echo "error: pid $$pid is not listening on 127.0.0.1:$$port after 10s" >&2; \
	        echo "--- $$log ---"; cat $$log 2>/dev/null; exit 1; \
	    fi; \
	done
	@echo "::: harness up — dashboard :$(DASH_PORT), proxy :$(PROXY_PORT)$(if $(BLACKHOLE_FLAG), (BLACKHOLE),) :::"

.PHONY: harness-down
harness-down:  ## Stop the fake dashboard + stub proxy
	@# Wait for each process to actually exit before dropping its pidfile:
	@# harness-up runs this and then checks the ports, and a process still
	@# on its way out would look like a stray and block the start (M2 review).
	@for f in $(PROXY_PID) $(DASH_PID); do \
	    if [ -f $$f ]; then \
	        pid=$$(cat $$f); kill $$pid 2>/dev/null || true; \
	        for i in $$(seq 1 50); do kill -0 $$pid 2>/dev/null || break; sleep 0.1; done; \
	        rm -f $$f; \
	    fi; \
	done
	@echo "::: harness down :::"

.PHONY: harness-reap
harness-reap:  ## Stop strays on the harness ports, pidfile or not
	@# Two independent ways to confirm a listener is ours before killing it,
	@# so this can never take out an unrelated service that happened to pick
	@# the same port:
	@#
	@#   1. its command line names one of this directory's two scripts;
	@#   2. its working directory IS this directory.
	@#
	@# Both are checked because `ps` is unavailable in some sandboxed shells
	@# (it fails with "operation not permitted"), and a reaper that silently
	@# declines to reap is a reaper that does not work when you need it.
	@# `lsof` reports cwd in those same shells, so (2) is the one that holds.
	@for port in $(DASH_PORT) $(DASH_CONTROL_PORT) $(PROXY_PORT) $(PROXY_CONTROL_PORT) $(GW_PORT) $(GW_CONTROL_PORT); do \
	    for pid in $$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null || true); do \
	        cmd=$$(ps -o command= -p $$pid 2>/dev/null || true); \
	        cwd=$$(lsof -a -p $$pid -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1); \
	        mine=0; \
	        case "$$cmd" in *dashboard.py*|*socks5stub.py*|*fake_gateway.py*) mine=1;; esac; \
	        [ "$$cwd" = "$(CURDIR)" ] && mine=1; \
	        if [ $$mine -eq 1 ]; then \
	            echo "reaping pid $$pid on :$$port"; kill $$pid 2>/dev/null || true; \
	        else \
	            echo "pid $$pid on :$$port is not a harness process; leaving it alone" >&2; \
	            echo "  command: $${cmd:-<unreadable>}" >&2; \
	            echo "  cwd:     $${cwd:-<unreadable>}" >&2; \
	        fi; \
	    done; \
	done
	@rm -f $(PROXY_PID) $(DASH_PID) $(GW_PID)
	@echo "::: strays reaped :::"

.PHONY: bundle
bundle:  ## Fetch the pinned KiroCrew wheel (a no-op when cached and intact)
	@$(PY) fake_gateway.py --fetch

.PHONY: gateway-up
gateway-up: certs gateway-down  ## Start the fake KiroCrew gateway (GW_EXPIRE_IN=seconds)
	@mkdir -p $(RUN_DIR)
	@for port in $(GW_PORT) $(GW_CONTROL_PORT); do \
	    if lsof -nP -iTCP:$$port -sTCP:LISTEN -t >/dev/null 2>&1; then \
	        echo "error: 127.0.0.1:$$port is already in use (a stray? make harness-reap)" >&2; exit 1; \
	    fi; \
	done
	@$(PY) fake_gateway.py --port $(GW_PORT) --control-port $(GW_CONTROL_PORT) \
		--cert server.pem --key server.key --expire-in $(GW_EXPIRE_IN) \
		> $(GW_LOG) 2>&1 & echo $$! > $(GW_PID)
	@pid=$$(cat $(GW_PID)); ok=0; \
	for i in $$(seq 1 100); do \
	    if ! kill -0 $$pid 2>/dev/null; then \
	        echo "error: the fake gateway exited during startup:" >&2; cat $(GW_LOG) >&2; exit 1; \
	    fi; \
	    if lsof -nP -iTCP:$(GW_PORT) -sTCP:LISTEN -t 2>/dev/null | grep -qx "$$pid"; then ok=1; break; fi; \
	    sleep 0.1; \
	done; \
	if [ $$ok -ne 1 ]; then echo "error: the fake gateway is not listening after 10s" >&2; cat $(GW_LOG) >&2; exit 1; fi
	@echo "::: fake gateway up — https://gw.tail-scale.ts.net via the stub, :$(GW_PORT), control :$(GW_CONTROL_PORT) :::"

.PHONY: gateway-down
gateway-down:  ## Stop the fake KiroCrew gateway
	@if [ -f $(GW_PID) ]; then \
	    pid=$$(cat $(GW_PID)); kill $$pid 2>/dev/null || true; \
	    for i in $$(seq 1 50); do kill -0 $$pid 2>/dev/null || break; sleep 0.1; done; \
	    rm -f $(GW_PID); \
	fi

.PHONY: gateway-check
gateway-check: gateway-up  ## Host-side contract self-test of the fake gateway
	@status=0; $(PY) gateway_check.py --port $(GW_PORT) --control-port $(GW_CONTROL_PORT) --ca ca.pem || status=$$?; \
	$(MAKE) --no-print-directory gateway-down; exit $$status

.PHONY: harness-status
harness-status:  ## Show what is running
	@for f in $(DASH_PID) $(PROXY_PID); do \
	    if [ -f $$f ] && kill -0 $$(cat $$f) 2>/dev/null; then \
	        echo "running: $$f -> $$(cat $$f)"; \
	    else \
	        echo "stopped: $$f"; \
	    fi; \
	done

.PHONY: check
check: harness-up  ## Self-test the harness host-side with curl (no simulator)
	@# Negative checks are explicit `if ...; then exit 1; fi`, never `! cmd`:
	@# POSIX tells `set -e` to ignore a command starting with `!`, so a
	@# `! curl ...` that should fail the check can never fail it (M2 review).
	@set -e; \
	CTL=http://127.0.0.1:$(PROXY_CONTROL_PORT); DCTL=http://127.0.0.1:$(DASH_CONTROL_PORT); \
	PX=socks5h://$(PROXY_USER):$(PROXY_PASS)@127.0.0.1:$(PROXY_PORT); \
	count() { curl -s $$DCTL/__state | $(PY) -c "import json,sys; print(json.load(sys.stdin)['requests'].get('$$1', 0))"; }; \
	echo "==> HTTPS GET through the proxy (the tailnet-name path)"; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "FAKE DASHBOARD"; echo "    ok"; \
	echo "==> a wrong proxy password is rejected"; \
	if curl -sS --fail --cacert ca.pem --proxy socks5h://$(PROXY_USER):wrong@127.0.0.1:$(PROXY_PORT) https://$(DASH_HOST)/ >/dev/null 2>&1; then \
	    echo "FAIL: a wrong password got through" >&2; exit 1; fi; echo "    ok"; \
	echo "==> the journal (file and control port) recorded the CONNECT"; \
	grep -q '"event": *"connect"' $(JOURNAL); curl -s $$CTL/journal | grep -q '"connect"'; echo "    ok"; \
	echo "==> a client that connects and never speaks stalls nobody (tls_accept)"; \
	$(PY) -c "import subprocess, sys; from tls_accept import with_silent_client; \
	    r = with_silent_client($(DASH_PORT), lambda: subprocess.run(['curl', '-sS', '--fail', '--max-time', '5', \
	        '--cacert', 'ca.pem', 'https://dash.localtest.me:$(DASH_PORT)/'], capture_output=True)); sys.exit(r.returncode)" \
	    || { echo "FAIL: a silent client stalled the fake dashboard" >&2; exit 1; }; echo "    ok"; \
	echo "==> R10 positive control: a DIRECT load of dash.localtest.me succeeds"; \
	curl -s -X POST $$DCTL/__reset >/dev/null; \
	curl -sS --fail --cacert ca.pem https://dash.localtest.me:$(DASH_PORT)/ | grep -q "FAKE DASHBOARD"; \
	test "$$(count dash.localtest.me)" -ge 1; echo "    ok (a leak to this origin WOULD succeed, so a leak is detectable)"; \
	echo "==> R10 negative: blackholed proxy fails, dashboard sees ZERO requests"; \
	curl -s -X POST $$DCTL/__reset >/dev/null; curl -s -X POST "$$CTL/mode?blackhole=1" >/dev/null; \
	if curl -sS --fail --max-time 10 --cacert ca.pem --proxy $$PX https://dash.localtest.me:$(DASH_PORT)/ >/dev/null 2>&1; then \
	    echo "FAIL: a blackholed proxy let the load through" >&2; exit 1; fi; \
	test "$$(count dash.localtest.me)" -eq 0; \
	curl -s $$CTL/journal | grep -q '"blackhole": true'; echo "    ok"; \
	curl -s -X POST "$$CTL/mode?blackhole=0" >/dev/null; \
	echo "==> R10 stub-gone variant: a closed listener refuses at TCP level"; \
	curl -s -X POST $$CTL/close >/dev/null; \
	if curl -sS --fail --max-time 5 --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ >/dev/null 2>&1; then \
	    echo "FAIL: a closed proxy listener still served the load" >&2; exit 1; fi; \
	curl -s -X POST $$CTL/open >/dev/null; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "FAKE DASHBOARD"; echo "    ok (and it recovers on /open)"; \
	echo "==> M6: a report is stamped with the time the server received it"; \
	curl -s -X POST $$DCTL/__reset >/dev/null; \
	curl -sS --fail --cacert ca.pem -H 'Content-Type: application/json' -d '{"doc":"probe"}' \
	    https://dash.localtest.me:$(DASH_PORT)/__report >/dev/null; \
	curl -s $$DCTL/__state | $(PY) -c "import json, sys, time; r = json.load(sys.stdin)['reports']['dash.localtest.me']; \
	    assert abs(r['received_at'] - time.time()) < 5 and r['received_seq'] >= 1, r"; echo "    ok"; \
	echo "==> F4 D10: /__mode?front=502 answers 5xx on a LIVE connection, from the control port"; \
	curl -sS --fail -X POST "$$DCTL/__mode?front=502" | grep -q '"front": *502'; \
	code=$$(curl -s -o /tmp/front502.body -w '%{http_code}' --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/); \
	if [ "$$code" != "502" ]; then echo "FAIL: front=502 served $$code, not 502" >&2; exit 1; fi; \
	if [ -s /tmp/front502.body ]; then echo "FAIL: the 502 carried a body; ReverseProxy sends none" >&2; exit 1; fi; \
	curl -s $$DCTL/__state | grep -q '"front": *502'; \
	curl -sS --fail -X POST "$$DCTL/__mode?front=0" >/dev/null; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "FAKE DASHBOARD"; \
	rm -f /tmp/front502.body; echo "    ok (and front=0 restores the page)"; \
	echo "==> ...and a bad front value is refused rather than silently ignored"; \
	code=$$(curl -s -o /dev/null -w '%{http_code}' -X POST "$$DCTL/__mode?front=200"); \
	if [ "$$code" != "400" ]; then echo "FAIL: front=200 answered $$code, not 400" >&2; exit 1; fi; echo "    ok"; \
	echo "==> F9 §6 / F15 §6: the inset and shell probes, their viewports, /__mode?root= and /__state's insets"; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/__inset-cover | grep -q 'content="width=device-width, viewport-fit=cover"'; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/__inset-plain | grep -q 'content="width=device-width"'; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/__inset-product | grep -q 'interactive-widget=resizes-content, viewport-fit=cover"'; \
	curl -sS --fail -X POST "$$DCTL/__mode?root=cover" | grep -q '"root": *"cover"'; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "INSET PROBE cover"; \
	curl -sS --fail -X POST "$$DCTL/__mode?root=shell" | grep -q '"root": *"shell"'; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "SHELL PROBE"; \
	curl -sS --fail -X POST "$$DCTL/__mode?root=page" >/dev/null; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "FAKE DASHBOARD"; \
	curl -s -X POST $$DCTL/__reset >/dev/null; \
	curl -sS --fail --cacert ca.pem -d '{"probe":"shell","scrollTop":0}' https://dash.localtest.me:$(DASH_PORT)/__inset-report >/dev/null; \
	curl -sS --fail --cacert ca.pem -d '{"probe":"cover","top":"62px"}' https://dash.localtest.me:$(DASH_PORT)/__inset-report >/dev/null; \
	curl -s $$DCTL/__state | $(PY) -c "import json, sys; r = json.load(sys.stdin)['insets']['cover']; assert r['top'] == '62px' and r['received_seq'] >= 1, r"; \
	code=$$(curl -s -o /dev/null -w '%{http_code}' --cacert ca.pem -d '{"probe":"nope"}' https://dash.localtest.me:$(DASH_PORT)/__inset-report); \
	if [ "$$code" != "400" ]; then echo "FAIL: an unknown probe answered $$code, not 400" >&2; exit 1; fi; echo "    ok"; \
	echo "==> F6: the TLS handshake counter sees a connection by its SNI, and /__reset clears it"; \
	hs() { curl -s $$DCTL/__state | $(PY) -c "import json,sys; print(json.load(sys.stdin)['handshakes'].get('$$1', 0))"; }; \
	curl -s -X POST $$DCTL/__reset >/dev/null; \
	curl -sS --fail --cacert ca.pem https://dash.localtest.me:$(DASH_PORT)/healthz >/dev/null; \
	if [ "$$(hs dash.localtest.me)" -lt 1 ]; then echo "FAIL: a handshake with SNI dash.localtest.me was not counted" >&2; exit 1; fi; \
	curl -s -X POST $$DCTL/__reset >/dev/null; \
	if [ "$$(hs dash.localtest.me)" -ne 0 ]; then echo "FAIL: /__reset left the handshake count" >&2; exit 1; fi; echo "    ok"; \
	echo "==> F6: /single-origin, /__mode?root=single, and its /f6/ resources"; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/single-origin | grep -q "SINGLE ORIGIN"; \
	curl -sS --fail -X POST "$$DCTL/__mode?root=single" | grep -q '"root": *"single"'; \
	curl -s $$DCTL/__state | grep -q '"root": *"single"'; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "SINGLE ORIGIN"; \
	curl -sS --fail -X POST "$$DCTL/__mode?root=page" >/dev/null; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "FAKE DASHBOARD"; \
	loc=$$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/f6/redirect-img); \
	if [ "$$loc" != "302 https://dash.localtest.me:$(DASH_PORT)/f6/redirected.png" ]; then \
	    echo "FAIL: /f6/redirect-img answered '$$loc', not a 302 to the away origin" >&2; exit 1; fi; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/f6/inner | grep -q "https://dash.localtest.me:$(DASH_PORT)/f6/inner-img.png"; \
	curl -s -X POST $$DCTL/__reset >/dev/null; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://esm.sh/f6/cdn.js | grep -q "__F6_CDN"; \
	if [ "$$(count esm.sh)" -lt 1 ]; then echo "FAIL: esm.sh's request was not counted under its Host" >&2; exit 1; fi; echo "    ok"; \
	echo "==> F6: a lookalike CDN host WOULD be served and counted (the anchoring test's positive control)"; \
	curl -sS --fail --cacert ca.pem --proxy $$PX https://esm.sh.away.example/f6/pwn.js >/dev/null; \
	if [ "$$(count esm.sh.away.example)" -lt 1 ]; then echo "FAIL: esm.sh.away.example was not counted" >&2; exit 1; fi; echo "    ok"; \
	echo "==> M6: /__ws_push reaches an open WebSocket and /__drop_ws cuts it, as a gateway restart does"; \
	$(PY) -c "from dashboard import ws_drop_probe; ws_drop_probe($(DASH_PORT), $(DASH_CONTROL_PORT), 'ca.pem')"; echo "    ok"; \
	echo "==> M6.4: the page reconnects as KiroCrew's does (1 s doubling to 10 s, reset on open, refetch)"; \
	command -v node >/dev/null || { echo "FAIL: node is needed for page_check.js (brew install node)" >&2; exit 1; }; \
	node page_check.js
	@$(MAKE) --no-print-directory harness-down

.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help
