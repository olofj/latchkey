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
BIN          := $(RUN_DIR)/tsnet-harness
PID          := $(RUN_DIR)/tsnet-harness.pid
LOG          := $(RUN_DIR)/tsnet-harness.log
STATE        := $(CURDIR)/$(RUN_DIR)/state

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
	    -dashboard 127.0.0.1:$(DASH_PORT) -state $(STATE) > $(LOG) 2>&1 & echo $$! > $(PID)
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
	@if [ -f $(PID) ]; then \
	    pid=$$(cat $(PID)); kill $$pid 2>/dev/null || true; \
	    for i in $$(seq 1 50); do kill -0 $$pid 2>/dev/null || break; sleep 0.1; done; \
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
	@$(MAKE) -C ../harness --no-print-directory harness-up
	@status=0; \
	$(BIN) -selftest -ca ../harness/ca.pem -control 127.0.0.1:$(CONTROL_PORT) \
	    -api 127.0.0.1:$(API_PORT) -dashboard 127.0.0.1:$(DASH_PORT) -state $(STATE) || status=$$?; \
	$(MAKE) -C ../harness --no-print-directory harness-down >/dev/null; \
	rm -rf $(STATE); \
	exit $$status

.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help
