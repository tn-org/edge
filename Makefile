# ====== Config ======
# There is one .env, at the repo root. The only key read at parse time is APP_ENV, which
# structurally has to be known up front (sudo and the run-location guard). Everything else
# (ACME_EMAIL, INTERNAL_TOKEN, ...) is read inside the recipe or script that uses it.
# See docs/commands.md for the command list and the rules about where each one runs.
SHELL := /bin/bash

APP_ENV := $(strip $(shell grep '^APP_ENV=' .env 2>/dev/null | cut -d'=' -f2))
ifeq ($(APP_ENV),)
APP_ENV := local
endif

SUDO := $(if $(filter local,$(APP_ENV)),,sudo )
DOCKER ?= docker

COMPOSE ?= $(SUDO)$(DOCKER) compose -f docker-compose.yml

SCRIPTS := ./scripts

# Branch to follow on update. This repo only has main; override it to try something else.
DEPLOY_BRANCH ?= main

# ====== Run-location guard ======
# A server-only target starts its recipe with $(GUARD_SERVER) and sets the target-specific
# variable GUIDE to the correct one-line procedure.
# Location is decided by APP_ENV in the root .env (local = workstation, anything else = server).
GUARD_SERVER = @if [ "$(APP_ENV)" = "local" ]; then echo "make $@ is server-only (APP_ENV=$(APP_ENV))"; echo "-> $(GUIDE)"; exit 1; fi

.DEFAULT_GOAL := help

.PHONY: help up down restart ps logs render \
	update bans host-apply ban docker-prune env setup \
	db-up db-down db-create

help: # (prints the command list; hidden from the list itself)
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Stack

up: ## Start Traefik and CrowdSec [both]
	$(SCRIPTS)/render-config.sh
	$(COMPOSE) up -d

down: ## Stop Traefik and CrowdSec [both]
	$(COMPOSE) down

restart: ## Restart Traefik and CrowdSec [both]
	$(SCRIPTS)/render-config.sh
	$(COMPOSE) restart

ps: ## Show status [both]
	$(COMPOSE) ps

logs: ## View logs, TARGET=access|container (asks when omitted) [both]
	@target='$(TARGET)'; \
	if [ -z "$$target" ]; then \
		if [ -t 0 ]; then \
			echo "Select a log type:"; \
			target=$$(bash -c '. scripts/choose.sh && choose "Log type" access container'); \
		else \
			echo 'Usage: make logs TARGET=access|container [DOMAIN=] [SERVICE=]'; exit 1; \
		fi; \
	fi; \
	case "$$target" in \
		access) $(SCRIPTS)/view-logs.sh $(DOMAIN) ;; \
		container) $(COMPOSE) logs -f $(SERVICE) ;; \
		*) echo "Unknown TARGET: $$target (access|container)"; exit 1 ;; \
	esac

render: ## Apply .env values to the config files (Traefik static config, LAPI key, allowlist) [both]
	$(SCRIPTS)/render-config.sh

##@ Shared database (optional)

# The db profile is opt-in: on a server it is enabled through COMPOSE_PROFILES in .env so
# the normal up/update path carries it, while db-up starts the database alone (the local
# case, where Traefik and CrowdSec never run). The network is created here too, because
# on a workstation init.sh has usually never run.
db-up: ## Start the shared PostgreSQL instance only (creates the network if needed) [both]
	@password=$$(grep '^POSTGRES_PASSWORD=' .env 2>/dev/null | cut -d'=' -f2); \
	[ -n "$$password" ] || { echo "POSTGRES_PASSWORD is not set (make env KEY=POSTGRES_PASSWORD VALUE=...)"; exit 1; }
	@network=$$(grep '^EDGE_NETWORK=' .env 2>/dev/null | cut -d'=' -f2); \
	$(SUDO)$(DOCKER) network create "$${network:-edge}" >/dev/null 2>&1 || true
	$(COMPOSE) --profile db up -d postgres

db-down: ## Stop the shared PostgreSQL instance (data stays in the volume) [both]
	$(COMPOSE) --profile db stop postgres

db-create: ## Create a database and its owner role, NAME= [ROLE= PASSWORD=] (idempotent) [both]
	@$(SUDO)$(SCRIPTS)/db-create.sh '$(NAME)' '$(ROLE)' '$(PASSWORD)'

##@ Updates

# The only update path runs on the host; this repo has no mechanism to push itself out.
# Force git onto origin/$(DEPLOY_BRANCH), then run the new version of deploy-host.sh.
# Hosts that should follow automatically enable edge-update.timer (see README).
update: GUIDE = Run on the server: cd /app/edge && make update
update: ## Follow origin and apply the host layer (default main; override with DEPLOY_BRANCH=) [server]
	$(GUARD_SERVER)
	git fetch --all --prune
	git reset --hard origin/$(DEPLOY_BRANCH)
	$(SCRIPTS)/deploy-host.sh

##@ Monitoring and maintenance

bans: GUIDE = Run on the server: cd <repo> && make bans (CrowdSec only runs on the server)
bans: ## Show blocking status (display only, no notification) [server]
	$(GUARD_SERVER)
	@sudo $(SCRIPTS)/report.sh bans --no-notify

host-apply: GUIDE = Run on the server: cd <repo> && make host-apply
host-apply: ## Apply host config (log rotation, systemd timers, OS auto-updates) [server]
	$(GUARD_SERVER)
	$(SCRIPTS)/host-apply.sh

ban: GUIDE = Run on the server: cd <repo> && make ban (blocking only exists on the server)
ban: ## Block and allowlist operations (no args = interactive; CMD=list|ban|unban|allow|disallow|allowed [IP=]) [server]
	$(GUARD_SERVER)
	@$(SCRIPTS)/ban.sh '$(CMD)' '$(IP)'

docker-prune: GUIDE = Run on the server: cd <repo> && make docker-prune (the weekly docker-prune.timer is normally enough)
docker-prune: ## Remove unused docker images [server]
	$(GUARD_SERVER)
	$(SCRIPTS)/docker-prune.sh

##@ Environment and first run

env: ## Configure .env (no args = interactive; KEY= VALUE= sets one key; CMD=check compares) [both]
ifeq ($(CMD),check)
	@$(SCRIPTS)/check-env.sh
else ifneq ($(KEY),)
	@$(SCRIPTS)/env-setup.sh set '$(KEY)' '$(VALUE)'
else
	@$(SCRIPTS)/env-setup.sh
endif

setup: ## Full first-run wizard (repeatable and idempotent; initialises the host on a server) [both]
	@$(SCRIPTS)/setup.sh
