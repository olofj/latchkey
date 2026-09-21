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
#   make gateway-up      start the fake KiroCrew gateway (real 0.6.0 bundle, M4)
#   make gateway-down    stop it
#   make gateway-check   its host-side contract self-test (starts and stops it)
#
# The fake gateway is separate from harness-up on purpose: it refuses to start
# unless the installed KiroCrew bundle is the pinned one, and a KiroCrew
# upgrade must not take the offline (L1) suite down with it.
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
	curl -sS --fail --cacert ca.pem --proxy $$PX https://$(DASH_HOST)/ | grep -q "FAKE DASHBOARD"; echo "    ok (and it recovers on /open)"
	@$(MAKE) --no-print-directory harness-down

.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help
