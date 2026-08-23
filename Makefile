# ====== Config ======
# .env は repo ルート 1 本。唯一の parse 時読み取りは APP_ENV（sudo 要否と実行場所ガードに
# 構造的に必要）。それ以外（ACME_EMAIL / INTERNAL_TOKEN 等）は使う recipe / スクリプト内で読む。
# コマンド一覧と実行場所ルールは docs/commands.md を参照。
SHELL := /bin/bash

APP_ENV := $(strip $(shell grep '^APP_ENV=' .env 2>/dev/null | cut -d'=' -f2))
ifeq ($(APP_ENV),)
APP_ENV := local
endif

SUDO := $(if $(filter local,$(APP_ENV)),,sudo )
DOCKER ?= docker

COMPOSE ?= $(SUDO)$(DOCKER) compose -f docker-compose.yml

SCRIPTS := ./scripts

# デプロイ追従ブランチ（この repo は main 一本）
DEPLOY_BRANCH := main

# ====== 実行場所ガード ======
# server 専用 target は recipe 先頭に $(GUARD_SERVER) を置き、target 固有変数 GUIDE に正しい手順を 1 行で入れる。
# 実行場所は APP_ENV（root .env）で判定する（local = 開発機 / それ以外 = サーバー）。
GUARD_SERVER = @if [ "$(APP_ENV)" = "local" ]; then echo "❌ make $@ は server 専用（現在 APP_ENV=$(APP_ENV)）"; echo "👉 $(GUIDE)"; exit 1; fi

.DEFAULT_GOAL := help

.PHONY: help up down restart ps logs render \
	deploy-pull bans host-apply ban docker-prune env setup

help: #（コマンド一覧を表示。自身は一覧に出さない）
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ スタック運用

up: ## Traefik / CrowdSec 起動【両方】
	$(SCRIPTS)/render-config.sh
	$(COMPOSE) up -d

down: ## Traefik / CrowdSec 停止【両方】
	$(COMPOSE) down

restart: ## Traefik / CrowdSec 再起動【両方】
	$(SCRIPTS)/render-config.sh
	$(COMPOSE) restart

ps: ## 稼働状況【両方】
	$(COMPOSE) ps

logs: ## ログ閲覧 TARGET=access|container（未指定なら選択）【両方】
	@target='$(TARGET)'; \
	if [ -z "$$target" ]; then \
		if [ -t 0 ]; then \
			echo "ログ種別を選択:"; \
			target=$$(bash -c '. scripts/choose.sh && choose "ログ種別" access container'); \
		else \
			echo 'Usage: make logs TARGET=access|container [DOMAIN=] [SERVICE=]'; exit 1; \
		fi; \
	fi; \
	case "$$target" in \
		access) $(SCRIPTS)/view-logs.sh $(DOMAIN) ;; \
		container) $(COMPOSE) logs -f $(SERVICE) ;; \
		*) echo "❌ 不明な TARGET: $$target（access|container）"; exit 1 ;; \
	esac

render: ## .env の値を設定ファイルへ反映（Traefik 静的設定・LAPI キー・除外リスト）【両方】
	$(SCRIPTS)/render-config.sh

##@ デプロイ

deploy-pull: GUIDE = サーバー専用（CI が SSM 経由で実行）。手動なら サーバーで cd <repo> && make deploy-pull
deploy-pull: ## Git を origin/main へ強制追従（ホスト設定反映の前段）【server】
	$(GUARD_SERVER)
	git fetch --all --prune
	git reset --hard origin/$(DEPLOY_BRANCH)

##@ 監視・保守

bans: GUIDE = サーバーで実行: cd <repo> && make bans（CrowdSec はサーバーにのみ稼働）
bans: ## 遮断状況を表示（通知抑止・表示のみ）【server】
	$(GUARD_SERVER)
	@sudo $(SCRIPTS)/report.sh bans --no-notify

host-apply: GUIDE = サーバーで実行: cd <repo> && make host-apply
host-apply: ## ホスト側設定の一括反映（logrotate・systemd タイマー・OS 自動更新）【server】
	$(GUARD_SERVER)
	$(SCRIPTS)/host-apply.sh

ban: GUIDE = サーバーで実行: cd <repo> && make ban（遮断はサーバーにのみ存在）
ban: ## 遮断・除外リスト操作（無引数=対話 / CMD=list|ban|unban|allow|disallow|allowed [IP=]）【server】
	$(GUARD_SERVER)
	@$(SCRIPTS)/ban.sh '$(CMD)' '$(IP)'

docker-prune: GUIDE = サーバーで実行: cd <repo> && make docker-prune（通常は docker-prune.timer の週次で足りる）
docker-prune: ## 未使用 docker イメージの掃除【server】
	$(GUARD_SERVER)
	$(SCRIPTS)/docker-prune.sh

##@ 環境・初回

env: ## .env 設定（無引数=対話設定 / KEY= VALUE= で 1 キー直設定 / CMD=check で照合）【両方】
ifeq ($(CMD),check)
	@$(SCRIPTS)/check-env.sh
else ifneq ($(KEY),)
	@$(SCRIPTS)/env-setup.sh set '$(KEY)' '$(VALUE)'
else
	@$(SCRIPTS)/env-setup.sh
endif

setup: ## 初回セットアップ一括 wizard（再実行可・冪等。server はホスト初期化込み）【両方】
	@$(SCRIPTS)/setup.sh
