# L2 harness: a fake Tailscale control plane with real tsnet peers (PLAN M3,
# revision R17). The app's real embedded node joins it from the simulator,
# which shares this host's loopback.
#
#   make build   build the harness (the app's vendored tailscale, R16)
#   make up      start the fake dashboard (../harness) and this harness
#   make down    stop both
#   make reap    stop strays on this harness's ports
#   make check   host-side self-test, no simulator (~10 s)
#
# Ports: the control plane on 127.0.0.1:8490 (the app's -TestControlURL) and
# the test API on 127.0.0.1:8491. The dash peer forwards to the fake dashboard
# on 127.0.0.1:8443, which `up` starts through ../harness.

CONTROL_PORT ?= 8490
API_PORT     ?= 8491
DASH_PORT    ?= 8443
RUN_DIR      ?= .run
# Extra harness flags, e.g. HARNESS_ARGS="-gateway 127.0.0.1:8444 -slow-peer"
# for the discovery suite (M5). Plain `=`: only the make command line can set
# it, never an exported environment variable (M5 review).
HARNESS_ARGS =
BIN          := $(RUN_DIR)/tsnet-harness
PID          := $(RUN_DIR)/tsnet-harness.pid
LOG          := $(RUN_DIR)/tsnet-harness.log
STATE        := $(CURDIR)/$(RUN_DIR)/state
CHECK_STATE  := $(CURDIR)/$(RUN_DIR)/check-state

.PHONY: build
build:  ## Build the harness
	@mkdir -p $(RUN_DIR)
	@go build -o $(BIN) .

.PHONY: up
up: build down  ## Start the fake dashboard and the harness
	@$(MAKE) -C ../harness --no-print-directory harness-up
	@for port in $(CONTROL_PORT) $(API_PORT); do \
	    pids=$$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null || true); \
	    if [ -n "$$pids" ]; then \
	        echo "error: 127.0.0.1:$$port is already in use by pid(s): $$pids" >&2; \
	        echo "       Probably a stray from an earlier run: make reap" >&2; \
	        exit 1; \
	    fi; \
	done
	@rm -rf $(STATE)
	@$(BIN) -control 127.0.0.1:$(CONTROL_PORT) -api 127.0.0.1:$(API_PORT) \
	    -dashboard 127.0.0.1:$(DASH_PORT) -state $(STATE) $(HARNESS_ARGS) > $(LOG) 2>&1 & echo $$! > $(PID)
	@# Ready means OUR process answers /healthz: the first reset (peers up)
	@# has completed. A port probe alone would accept a stray (see ../harness).
	@pid=$$(cat $(PID)); ok=0; \
	for i in $$(seq 1 300); do \
	    if ! kill -0 $$pid 2>/dev/null; then \
	        echo "error: tsnet-harness (pid $$pid) exited during startup" >&2; cat $(LOG); exit 1; \
	    fi; \
	    if curl -sf http://127.0.0.1:$(API_PORT)/healthz >/dev/null 2>&1 \
	        && lsof -nP -iTCP:$(API_PORT) -sTCP:LISTEN -t 2>/dev/null | grep -qx "$$pid"; then ok=1; break; fi; \
	    sleep 0.1; \
	done; \
	if [ $$ok -ne 1 ]; then echo "error: tsnet-harness not ready after 30s" >&2; cat $(LOG); exit 1; fi
	@echo "::: tsnet harness up — control http://127.0.0.1:$(CONTROL_PORT), api :$(API_PORT) :::"

.PHONY: down
down:  ## Stop the harness and the fake dashboard
	@# Kill the pid only if it is still ours (its cwd is this directory): a
	@# harness that died leaves its pidfile behind, and the number may since
	@# belong to something else (M3 review).
	@if [ -f $(PID) ]; then \
	    pid=$$(cat $(PID)); \
	    cwd=$$(lsof -a -p $$pid -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1); \
	    if [ "$$cwd" = "$(CURDIR)" ]; then \
	        kill $$pid 2>/dev/null || true; \
	        for i in $$(seq 1 50); do kill -0 $$pid 2>/dev/null || break; sleep 0.1; done; \
	    fi; \
	    rm -f $(PID); \
	fi
	@$(MAKE) -C ../harness --no-print-directory harness-down >/dev/null
	@echo "::: tsnet harness down :::"

.PHONY: reap
reap:  ## Stop strays on the harness ports (only processes run from here)
	@for port in $(CONTROL_PORT) $(API_PORT); do \
	    for pid in $$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null || true); do \
	        cwd=$$(lsof -a -p $$pid -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1); \
	        if [ "$$cwd" = "$(CURDIR)" ]; then \
	            echo "reaping pid $$pid on :$$port"; kill $$pid 2>/dev/null || true; \
	        else \
	            echo "pid $$pid on :$$port is not ours (cwd $${cwd:-<unreadable>}); leaving it" >&2; \
	        fi; \
	    done; \
	done
	@rm -f $(PID)
	@$(MAKE) -C ../harness --no-print-directory harness-reap

.PHONY: check
check: build  ## Host-side self-test (needs the fake dashboard; starts and stops it)
	@# Refuse to run over a live harness: this starts and stops the shared
	@# fake dashboard and needs the same ports (M3 review).
	@if [ -f $(PID) ] && kill -0 $$(cat $(PID)) 2>/dev/null; then \
	    echo "error: the harness is running (make up); stop it first with make down" >&2; exit 1; \
	fi
	@for port in $(CONTROL_PORT) $(API_PORT); do \
	    if lsof -nP -iTCP:$$port -sTCP:LISTEN -t >/dev/null 2>&1; then \
	        echo "error: 127.0.0.1:$$port is in use; a stray? make reap" >&2; exit 1; \
	    fi; \
	done
	@$(MAKE) -C ../harness --no-print-directory harness-up
	@status=0; \
	$(BIN) -selftest -ca ../harness/ca.pem -control 127.0.0.1:$(CONTROL_PORT) \
	    -api 127.0.0.1:$(API_PORT) -dashboard 127.0.0.1:$(DASH_PORT) -state $(CHECK_STATE) \
	    -gateway 127.0.0.1:$(DASH_PORT) -slow-peer || status=$$?; \
	$(MAKE) -C ../harness --no-print-directory harness-down >/dev/null; \
	rm -rf $(CHECK_STATE); \
	exit $$status

.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help
