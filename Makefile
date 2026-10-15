MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := dev/up
.DELETE_ON_ERROR:
.SUFFIXES:

# include makefiles
export SELF ?= $(MAKE)
PROJECT_PATH ?= $(shell pwd)
include $(PROJECT_PATH)/Makefile.*

REPO_NAME ?= $(shell basename $(CURDIR))

# Set FORCE=true to skip confirmation prompts and overwrite generated artifacts
FORCE ?= false

# Limit a target to a single compose service, e.g. SERVICE=langfuse-worker make docker/logs
# Empty (the default) applies the target to every service.
SERVICE ?=

#-------------------------------------------------------------------------------
# langfuse
#-------------------------------------------------------------------------------

# Upstream source. LANGFUSE_VERSION accepts any git ref (branch, tag, sha).
# Pinned to a release so every clone deploys the same compose file; bump it
# deliberately, or follow upstream with LANGFUSE_VERSION=main make dev/up.
LANGFUSE_REPO_URL ?= https://github.com/langfuse/langfuse.git
LANGFUSE_VERSION ?= v4.48.0
LANGFUSE_SRC_PATH ?= $(PROJECT_PATH)/.langfuse

# Env file lives in this repo, not in the upstream clone, so the checkout stays
# pristine and re-cloning never clobbers local configuration.
LANGFUSE_ENV_FILE ?= $(PROJECT_PATH)/.env

# Externally reachable URL of the web container. Must match how users browse to
# Langfuse or NextAuth callbacks will fail, e.g. LANGFUSE_URL=http://10.0.0.5:3000
LANGFUSE_WEB_PORT ?= 3000
LANGFUSE_URL ?= http://localhost:$(LANGFUSE_WEB_PORT)

# Datastore credentials used by the backup and restore targets. Passwords are
# read from the env file at runtime rather than duplicated here, so rotating a
# secret needs no Makefile change.
LANGFUSE_POSTGRES_USER ?= postgres
LANGFUSE_POSTGRES_DB ?= postgres
LANGFUSE_CLICKHOUSE_USER ?= clickhouse
LANGFUSE_CLICKHOUSE_DB ?= default

# Services that read the env file's app-level secrets, and so must be recreated
# whenever those change (bootstrap provisioning, restored ENCRYPTION_KEY).
LANGFUSE_APP_SERVICES ?= langfuse-web langfuse-worker

# Verify required host dependencies are installed
langfuse/check:
	@command -v git > /dev/null 2>&1 || (echo "[ERROR] git is not installed." && exit 1)
	@command -v openssl > /dev/null 2>&1 || (echo "[ERROR] openssl is not installed." && exit 1)
	@command -v curl > /dev/null 2>&1 || (echo "[ERROR] curl is not installed." && exit 1)
.PHONY: langfuse/check

# The one pre-flight target: host tools, Docker, and -- only when tracing is set
# up -- each harness's needs, so it never fails over tools tracing would need
# for someone who does not trace. The three parts still run on their own as
# prerequisites of the targets that need them.
## Verify host tools, Docker and (when tracing) each harness's needs
check: langfuse/check docker/daemon
	@set -eu; \
	wanted=false; \
	if command -v python3 > /dev/null 2>&1; then \
		for harness in $(TRACE_HARNESSES); do \
			if $(TRACE_HARNESS) wanted $$harness; then wanted=true; fi; \
		done; \
	fi; \
	if [ "$$wanted" = "true" ]; then \
		$(SELF) --no-print-directory trace/check; \
	else \
		echo "[INFO] Tracing is not set up, so its tools were not checked ('TRACE=true make check' includes them)."; \
	fi; \
	echo "[INFO] Host tools and Docker are ready."
.PHONY: check

# Clone or update langfuse source at LANGFUSE_VERSION. The clone is blobless:
# full history and refs, but file contents only for what gets checked out.
langfuse/clone: langfuse/check
	@if [ -d "$(LANGFUSE_SRC_PATH)/.git" ]; then \
		echo "[INFO] Langfuse source already present at '$(LANGFUSE_SRC_PATH)'."; \
	else \
		echo "[INFO] Cloning '$(LANGFUSE_REPO_URL)' into '$(LANGFUSE_SRC_PATH)'."; \
		git clone --quiet --filter=blob:none "$(LANGFUSE_REPO_URL)" "$(LANGFUSE_SRC_PATH)"; \
	fi
	@echo "[INFO] Checking out langfuse '$(LANGFUSE_VERSION)'."
	@git -C "$(LANGFUSE_SRC_PATH)" fetch --quiet --tags origin
	@git -C "$(LANGFUSE_SRC_PATH)" checkout --quiet "$(LANGFUSE_VERSION)"
	@if git -C "$(LANGFUSE_SRC_PATH)" symbolic-ref --quiet HEAD > /dev/null 2>&1; then \
		git -C "$(LANGFUSE_SRC_PATH)" pull --quiet --ff-only; \
	fi
.PHONY: langfuse/clone

# Headless provisioning is written by default: Langfuse provisions an org, project
# and user ONLY on first start, and 'make trace/project' signs in with those same
# credentials. Leaving it out means the only ways back are 'make clean' (which
# destroys volumes) or creating the project by hand, so the default is to include
# it. HEADLESS=false writes a bare env file and you sign up through the UI.
HEADLESS ?= true

# Defaults for the block. The email is taken from git so the account matches the
# person running it; everything else derives from the repo or is generated.
HEADLESS_EMAIL ?= $(shell git config user.email 2>/dev/null)
HEADLESS_USER_NAME ?= $(shell git config user.name 2>/dev/null)
HEADLESS_ORG_ID ?= $(REPO_NAME)
# The ID is permanent once traces exist, so it keeps its original value; the
# display name is only a label and says what the project now holds.
HEADLESS_PROJECT_ID ?= claude-code-skills
HEADLESS_PROJECT_NAME ?= Coding Agents

## Generate env file with random secrets (headless provisioning by default)
langfuse/env: langfuse/check
	@if [ -f "$(LANGFUSE_ENV_FILE)" ] && [ "$(FORCE)" != "true" ]; then \
		echo "[INFO] Env file '$(LANGFUSE_ENV_FILE)' already exists. Use 'FORCE=true' to regenerate."; \
		exit 0; \
	fi; \
	if [ -f "$(LANGFUSE_ENV_FILE)" ]; then \
		echo "[WARN] Overwriting '$(LANGFUSE_ENV_FILE)'. Existing data encrypted with the old ENCRYPTION_KEY will be unreadable."; \
		cp "$(LANGFUSE_ENV_FILE)" "$(LANGFUSE_ENV_FILE).bak"; \
		echo "[INFO] Previous env file backed up to '$(LANGFUSE_ENV_FILE).bak'."; \
	fi; \
	echo "[INFO] Generating env file '$(LANGFUSE_ENV_FILE)'."; \
	postgres_password="$$(openssl rand -hex 24)"; \
	clickhouse_password="$$(openssl rand -hex 24)"; \
	minio_password="$$(openssl rand -hex 24)"; \
	redis_password="$$(openssl rand -hex 24)"; \
	nextauth_secret="$$(openssl rand -hex 32)"; \
	salt="$$(openssl rand -hex 32)"; \
	encryption_key="$$(openssl rand -hex 32)"; \
	printf '%s\n' \
		"# Langfuse docker compose configuration." \
		"# Generated by 'make langfuse/env' -- DO NOT COMMIT. Regenerating the" \
		"# ENCRYPTION_KEY makes existing encrypted data (API keys, LLM credentials)" \
		"# permanently unreadable, so back this file up alongside your volumes." \
		"" \
		"# --- web ---" \
		"NEXTAUTH_URL=$(LANGFUSE_URL)" \
		"NEXTAUTH_SECRET=$$nextauth_secret" \
		"SALT=$$salt" \
		"ENCRYPTION_KEY=$$encryption_key" \
		"TELEMETRY_ENABLED=false" \
		"" \
		"# --- postgres ---" \
		"POSTGRES_PASSWORD=$$postgres_password" \
		"DATABASE_URL=postgresql://postgres:$$postgres_password@postgres:5432/postgres" \
		"" \
		"# --- clickhouse ---" \
		"CLICKHOUSE_USER=clickhouse" \
		"CLICKHOUSE_PASSWORD=$$clickhouse_password" \
		"" \
		"# --- redis ---" \
		"REDIS_AUTH=$$redis_password" \
		"" \
		"# --- minio (s3) ---" \
		"# All four values must match: minio serves the buckets langfuse writes to." \
		"MINIO_ROOT_USER=minio" \
		"MINIO_ROOT_PASSWORD=$$minio_password" \
		"LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=$$minio_password" \
		"LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY=$$minio_password" \
		"LANGFUSE_S3_BATCH_EXPORT_SECRET_ACCESS_KEY=$$minio_password" \
		> "$(LANGFUSE_ENV_FILE)"; \
	chmod 600 "$(LANGFUSE_ENV_FILE)"; \
	if [ "$(HEADLESS)" != "true" ]; then \
		echo "[INFO] HEADLESS=false: no provisioning block written. Sign up at $(LANGFUSE_URL)."; \
		exit 0; \
	fi; \
	if [ -z "$(HEADLESS_EMAIL)" ]; then \
		echo "[ERROR] No git user.email set, so the provisioning account has no address."; \
		echo "[ERROR] Set one (git config --global user.email you@example.com) and re-run,"; \
		echo "[ERROR] pass HEADLESS_EMAIL=you@example.com, or use HEADLESS=false."; \
		exit 1; \
	fi; \
	user_password="$$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"; \
	printf '%s\n' \
		"" \
		"# --- headless bootstrap (generated by 'make langfuse/env') ---" \
		"# Applied by the web container on FIRST START only. The API key pair is" \
		"# pinned here on purpose: after 'make docker/clean' (volumes wiped, this" \
		"# file kept) bootstrap recreates these same keys in the fresh database, so" \
		"# apps configured with them keep working. 'make clean' deletes this file" \
		"# too, so a full clean always issues new keys." \
		"# Display names may contain spaces: compose parses this file itself, but" \
		"# that means 'source .env' in a shell will fail on them. Do not source it." \
		"LANGFUSE_INIT_ORG_ID=$(HEADLESS_ORG_ID)" \
		"LANGFUSE_INIT_PROJECT_ID=$(HEADLESS_PROJECT_ID)" \
		"LANGFUSE_INIT_PROJECT_NAME=$(HEADLESS_PROJECT_NAME)" \
		"LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-$$(openssl rand -hex 16)" \
		"LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-$$(openssl rand -hex 16)" \
		"LANGFUSE_INIT_USER_EMAIL=$(HEADLESS_EMAIL)" \
		"LANGFUSE_INIT_USER_PASSWORD=$$user_password" \
		>> "$(LANGFUSE_ENV_FILE)"; \
	if [ -n "$(HEADLESS_USER_NAME)" ]; then \
		printf 'LANGFUSE_INIT_USER_NAME=%s\n' "$(HEADLESS_USER_NAME)" >> "$(LANGFUSE_ENV_FILE)"; \
	fi; \
	echo "[INFO] Wrote headless provisioning for '$(HEADLESS_EMAIL)'."; \
	echo "[INFO] Sign in at $(LANGFUSE_URL) with that address, password: $$user_password"
.PHONY: langfuse/env

# Seconds to wait for the web service to report healthy.
LANGFUSE_WAIT_TIMEOUT ?= 300

# Lives here rather than under docker/ because it is a Langfuse health check, not
# generic compose plumbing: it polls the app's own /api/public/health.
# Wait for the langfuse web service to become healthy
langfuse/wait: docker/check
	@echo "[INFO] Waiting up to $(LANGFUSE_WAIT_TIMEOUT)s for '$(LANGFUSE_URL)'."
	@elapsed=0; \
	until curl --silent --fail --output /dev/null "$(LANGFUSE_URL)/api/public/health"; do \
		if [ "$$elapsed" -ge "$(LANGFUSE_WAIT_TIMEOUT)" ]; then \
			echo "[ERROR] Timed out waiting for langfuse. Check 'make docker/logs'."; \
			exit 1; \
		fi; \
		sleep 5; \
		elapsed=$$((elapsed + 5)); \
	done; \
	echo "[INFO] Langfuse is ready at '$(LANGFUSE_URL)'."
.PHONY: langfuse/wait

# Variables that must be set for headless provisioning. The NAME fields and the
# API key pair are optional: without keys Langfuse still creates the org,
# project and user, but keys must then be made in the UI.
LANGFUSE_INIT_REQUIRED ?= \
	LANGFUSE_INIT_ORG_ID \
	LANGFUSE_INIT_PROJECT_ID \
	LANGFUSE_INIT_USER_EMAIL \
	LANGFUSE_INIT_USER_PASSWORD

# True when every required LANGFUSE_INIT_* has a non-empty value in the env file.
# Recursively expanded so it is evaluated per-recipe, after langfuse/env has run.
LANGFUSE_INIT_CONFIGURED = $(shell \
	[ -f "$(LANGFUSE_ENV_FILE)" ] || { echo false; exit 0; }; \
	for var in $(LANGFUSE_INIT_REQUIRED); do \
		grep -qE "^$$var=." "$(LANGFUSE_ENV_FILE)" || { echo false; exit 0; }; \
	done; \
	echo true)

# When true, langfuse/bootstrap exits quietly if no LANGFUSE_INIT_* is set
# instead of failing. 'dev/up' sets this so headless provisioning stays opt-in.
BOOTSTRAP_OPTIONAL ?= false

## Provision the initial org, project, user and API keys
langfuse/bootstrap: docker/check
	@# One shell for the whole recipe. Make runs each recipe line in its own
	@# shell, so an early 'exit 0' in a multi-line recipe ends only that line and
	@# the rest still runs -- which silently produced a pointless container
	@# recreate when nothing was configured. Keeping this as a single shell means
	@# the no-op path can return immediately.
	@set -eu; \
	env_file="$(LANGFUSE_ENV_FILE)"; \
	if [ ! -f "$$env_file" ]; then \
		echo "[ERROR] Env file '$$env_file' not found. Run 'make langfuse/env'."; \
		exit 1; \
	fi; \
	if [ "$(LANGFUSE_INIT_CONFIGURED)" != "true" ]; then \
		if [ "$(BOOTSTRAP_OPTIONAL)" = "true" ]; then \
			exit 0; \
		fi; \
		echo "[ERROR] Headless provisioning needs these unset variables:"; \
		for var in $(LANGFUSE_INIT_REQUIRED); do \
			grep -qE "^$$var=." "$$env_file" || echo "[ERROR]   $$var"; \
		done; \
		echo "[ERROR] See the 'headless bootstrap' block in .env.example, then re-run."; \
		exit 1; \
	fi; \
	read_var() { grep -E "^$$1=" "$$env_file" | cut -d= -f2-; }; \
	psql_q() { \
		$(DOCKER_COMPOSE) exec --no-TTY postgres \
			psql --tuples-only --no-align --quiet \
				--username "$(LANGFUSE_POSTGRES_USER)" --dbname "$(LANGFUSE_POSTGRES_DB)" \
				--command "$$1" 2>/dev/null | tr -d '\r'; \
	}; \
	public_key="$$(read_var LANGFUSE_INIT_PROJECT_PUBLIC_KEY)"; \
	secret_key="$$(read_var LANGFUSE_INIT_PROJECT_SECRET_KEY)"; \
	init_email="$$(read_var LANGFUSE_INIT_USER_EMAIL)"; \
	if [ -z "$$public_key" ] || [ -z "$$secret_key" ]; then \
		echo "[WARN] LANGFUSE_INIT_PROJECT_PUBLIC_KEY / _SECRET_KEY unset."; \
		echo "[WARN] The account will be created but no API keys; make them in the UI."; \
	fi; \
	existing="$$(psql_q 'SELECT count(*) FROM users' || echo 0)"; \
	if [ "$${existing:-0}" -gt 0 ]; then \
		if [ "$(BOOTSTRAP_OPTIONAL)" != "true" ]; then \
			echo "[WARN] $$existing user(s) already exist, so LANGFUSE_INIT_* will not be applied."; \
			echo "[WARN] Langfuse only provisions on first run. To re-provision from scratch:"; \
			echo "[WARN]   make langfuse/backup   # if you want the current data"; \
			echo "[WARN]   make clean && make dev/up && make langfuse/bootstrap"; \
			echo "[WARN] Reporting existing state instead."; \
		fi; \
	else \
		echo "[INFO] Recreating app services to apply LANGFUSE_INIT_* for '$$init_email'."; \
		$(DOCKER_COMPOSE) up $(DOCKER_COMPOSE_UP_ARGS) --force-recreate \
			$(LANGFUSE_APP_SERVICES) > /dev/null 2>&1; \
		$(SELF) --no-print-directory langfuse/wait; \
	fi; \
	echo "[INFO] Provisioned state:"; \
	psql_q "SELECT '[INFO]   org:     ' || id || ' (' || name || ')' FROM organizations"; \
	psql_q "SELECT '[INFO]   project: ' || id || ' (' || name || ')' FROM projects"; \
	psql_q "SELECT '[INFO]   user:    ' || email FROM users"; \
	if [ -n "$$public_key" ] && [ -n "$$secret_key" ]; then \
		if curl --silent --fail --max-time 15 --user "$$public_key:$$secret_key" \
			"$(LANGFUSE_URL)/api/public/projects" > /dev/null 2>&1; then \
			echo "[INFO]   api keys: verified against $(LANGFUSE_URL)"; \
			echo "[INFO]"; \
			echo "[INFO] Point your application at:"; \
			echo "[INFO]   LANGFUSE_HOST=$(LANGFUSE_URL)"; \
			echo "[INFO]   LANGFUSE_PUBLIC_KEY=$$public_key"; \
			echo "[INFO]   LANGFUSE_SECRET_KEY=$$secret_key"; \
			echo "[INFO] This deploys Langfuse v4: use a v4 SDK or the OTLP endpoint at"; \
			echo "[INFO] $(LANGFUSE_URL)/api/public/otel/v1/traces (v3 SDKs are rejected)."; \
		else \
			echo "[WARN]   api keys: NOT accepted by $(LANGFUSE_URL)"; \
			echo "[WARN] The keys in the env file differ from those in the database."; \
			echo "[WARN] Provisioning ran earlier with different values; create keys in the UI"; \
			echo "[WARN] or re-provision from scratch (see the warning above)."; \
		fi; \
	fi; \
	echo "[INFO] Sign in at $(LANGFUSE_URL)"
.PHONY: langfuse/bootstrap

#-------------------------------------------------------------------------------
# coding agent tracing
#-------------------------------------------------------------------------------
# Tracing is done by each harness's official Langfuse plugin, which reads the
# harness's transcript and emits one trace per turn with the conversation on it.
# Credentials live in the plugin's own machine-scope config -- never in a repo.
# These targets only:
#
#   trace/project  create the tracing project and one key pair per harness
#   trace/install  install and configure each harness's plugin with its pair
#   trace/tag      label a repo's traces (for Codex, also enable the plugin there)
#
# The per-harness logic lives in scripts/trace_harness.py. Adding a harness is a
# class there plus its name in TRACE_HARNESSES; nothing here changes.

# Harnesses to trace. Each gets its own key pair in .env,
# LANGFUSE_TRACE_<HARNESS>_PUBLIC_KEY / _SECRET_KEY, so one can be revoked without
# touching the others. All of them write to the same project: splitting by
# harness would make "how does this skill behave across harnesses" unanswerable.
TRACE_HARNESSES ?= claude

# When true, the trace targets exit quietly for a harness where nothing indicates
# tracing is wanted. 'dev/up' sets this so tracing stays opt-in -- the same
# pattern BOOTSTRAP_OPTIONAL uses for headless provisioning.
TRACE_OPTIONAL ?= false

# Forces tracing on for a first run, before a key pair or configured plugin
# exists to signal it:  TRACE=true make dev/up
TRACE ?= false

# Value of a variable in the env file, or empty. Recursively expanded wherever it
# is used, so it reads the file as it is after langfuse/env has run.
env_value = $(shell [ -f "$(LANGFUSE_ENV_FILE)" ] && sed -n 's/^$(1)=//p' "$(LANGFUSE_ENV_FILE)" | tail -1)

# The project traces land in. Found by ID first, so renaming its display name
# never creates a second project; by name when there is no known ID (a stack
# set up through the UI). LANGFUSE_TRACE_PROJECT_NAME in .env overrides the name.
TRACE_PROJECT_ID = $(or $(call env_value,LANGFUSE_INIT_PROJECT_ID),$(HEADLESS_PROJECT_ID))
TRACE_PROJECT_NAME = $(or $(call env_value,LANGFUSE_TRACE_PROJECT_NAME),$(HEADLESS_PROJECT_NAME))

# Langfuse user attached to traces where the plugin allows it (Codex), so every
# harness reports the account's email rather than its own login identity.
TRACE_USER_ID = $(or $(call env_value,LANGFUSE_INIT_USER_EMAIL),$(HEADLESS_EMAIL))

TRACE_HARNESS = \
	ENV_FILE="$(LANGFUSE_ENV_FILE)" \
	LANGFUSE_URL="$(LANGFUSE_URL)" \
	TRACE="$(TRACE)" \
	OPTIONAL="$(TRACE_OPTIONAL)" \
	USER_ID="$(TRACE_USER_ID)" \
	python3 "$(PROJECT_PATH)/scripts/trace_harness.py"

# Under TRACE_OPTIONAL a missing python3 means "not tracing", not an error:
# 'dev/up' must still work for someone who never asked for tracing.
TRACE_NEED_PYTHON = \
	if ! command -v python3 > /dev/null 2>&1; then \
		if [ "$(TRACE_OPTIONAL)" = "true" ]; then exit 0; fi; \
		echo "[ERROR] python3 is not installed (needed by scripts/)."; \
		exit 1; \
	fi

# Verify the host tools tracing needs, for every harness in TRACE_HARNESSES
trace/check:
	@python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' \
		|| (echo "[ERROR] python3 3.10+ required, found $$(python3 -V 2>&1)." && exit 1)
	@echo "[INFO] python3 $$(python3 -V 2>&1 | cut -d' ' -f2) present."
	@set -eu; for harness in $(TRACE_HARNESSES); do \
		$(TRACE_HARNESS) check $$harness; \
	done
.PHONY: trace/check

# Ensure the tracing project and a key pair per harness exist (idempotent)
trace/project: docker/check
	@# One shell for the whole recipe so the no-op path returns immediately, as in
	@# langfuse/bootstrap.
	@set -eu; \
	if [ ! -f "$(LANGFUSE_ENV_FILE)" ]; then \
		if [ "$(TRACE_OPTIONAL)" = "true" ]; then exit 0; fi; \
		echo "[ERROR] Env file '$(LANGFUSE_ENV_FILE)' not found. Run 'make langfuse/env'."; \
		exit 1; \
	fi; \
	$(TRACE_NEED_PYTHON); \
	for harness in $(TRACE_HARNESSES); do \
		if [ "$(TRACE_OPTIONAL)" = "true" ] && ! $(TRACE_HARNESS) wanted $$harness; then \
			continue; \
		fi; \
		upper="$$(echo "$$harness" | tr '[:lower:]' '[:upper:]')"; \
		ENV_FILE="$(LANGFUSE_ENV_FILE)" \
		LANGFUSE_URL="$(LANGFUSE_URL)" \
		PROJECT_ID="$(TRACE_PROJECT_ID)" \
		PROJECT_NAME="$(TRACE_PROJECT_NAME)" \
		KEY_PREFIX="LANGFUSE_TRACE_$$upper" \
		KEY_NOTE="$$harness tracing (langfuse plugin)" \
		HEADING="# --- $$harness tracing (written by 'make trace/project') ---" \
		python3 "$(PROJECT_PATH)/scripts/langfuse_project.py"; \
	done
.PHONY: trace/project

## Create the tracing keys and configure each harness's plugin (idempotent)
trace/install: trace/project
	@# Machine scope: this affects every repo on this machine. Safe to run
	@# repeatedly -- a harness whose plugin already carries the current key pair
	@# is left alone, which is what lets 'dev/up' depend on it unconditionally.
	@set -eu; \
	$(TRACE_NEED_PYTHON); \
	for harness in $(TRACE_HARNESSES); do \
		$(TRACE_HARNESS) install $$harness; \
	done
.PHONY: trace/install

# Repo to label. Accepts a bare path after the target, e.g.
#   make trace/tag ~/Code/my-service
# Any goal that is an existing directory is taken as this argument rather than a
# target (see the rule at the end of this section). REPO_DIR=... also works.
#
# A goal is a path argument if it is an existing directory, or if it is spelled
# like a path (leading /, ./, ../ or ~). The second half matters: without it a
# mistyped path falls through to the default REPO_DIR and the target silently
# acts on THIS repo, erroring only afterwards -- by which point it has written.
REPO_DIR_ARG := $(strip $(foreach g,$(MAKECMDGOALS),\
	$(if $(wildcard $(g)/.),$(g),\
		$(if $(filter /% ./% ../% ~%,$(g)),$(g)))))

# Fail during parse, before any recipe runs, when a path-shaped goal is not a
# directory. $(error) here cannot be reached after a partial write.
REPO_DIR_MISSING := $(strip $(foreach g,$(REPO_DIR_ARG),$(if $(wildcard $(g)/.),,$(g))))
ifneq ($(REPO_DIR_MISSING),)
$(error Not a directory: $(REPO_DIR_MISSING))
endif

ifneq ($(words $(REPO_DIR_ARG)),0)
ifneq ($(words $(REPO_DIR_ARG)),1)
$(error Pass one path, got: $(REPO_DIR_ARG))
endif
endif

REPO_DIR ?= $(if $(REPO_DIR_ARG),$(REPO_DIR_ARG),$(PROJECT_PATH))

# Label written as repo:<label>. Defaults to the target directory's basename,
# which is the repo name in a normal clone -- and the same default litellm-helper
# uses for its proxy traces, so a repo carries one label in both projects.
REPO_LABEL ?= $(notdir $(abspath $(REPO_DIR)))

# Claude Code only. Committed by default so the label travels with the clone; it
# holds no secret. Point at settings.local.json for a personal, uncommitted label.
CLAUDE_SETTINGS_FILE ?=

## Label a repo's traces with repo:<name> and harness:<name> (idempotent)
trace/tag:
	@set -eu; for harness in $(TRACE_HARNESSES); do \
		REPO_DIR="$(abspath $(REPO_DIR))" \
		REPO_LABEL="$(REPO_LABEL)" \
		CLAUDE_SETTINGS_FILE="$(CLAUDE_SETTINGS_FILE)" \
		$(TRACE_HARNESS) tag $$harness; \
	done
	@echo "[INFO] Skill tags (skill:<name>) and cwd/git_branch metadata are automatic."
.PHONY: trace/tag

## Remove the repo:/harness: tags (and Codex's per-repo enable file) from a repo
trace/untag:
	@set -eu; for harness in $(TRACE_HARNESSES); do \
		REPO_DIR="$(abspath $(REPO_DIR))" \
		CLAUDE_SETTINGS_FILE="$(CLAUDE_SETTINGS_FILE)" \
		$(TRACE_HARNESS) untag $$harness; \
	done
.PHONY: trace/untag

# Let a bare directory path be passed after the target. Only paths that already
# exist are absorbed, so a mistyped target name still fails with make's own
# "No rule to make target" rather than silently doing nothing.
ifneq ($(REPO_DIR_ARG),)
.PHONY: $(REPO_DIR_ARG)
$(REPO_DIR_ARG):
	@:
endif

#-------------------------------------------------------------------------------
# docker
#-------------------------------------------------------------------------------

DOCKER_COMPOSE_FILE ?= $(LANGFUSE_SRC_PATH)/docker-compose.yml
DOCKER_COMPOSE_PROJECT ?= $(REPO_NAME)

DOCKER_COMPOSE_ARGS ?=
DOCKER_COMPOSE_ARGS += --project-name $(DOCKER_COMPOSE_PROJECT)
DOCKER_COMPOSE_ARGS += --project-directory $(LANGFUSE_SRC_PATH)
DOCKER_COMPOSE_ARGS += --file $(DOCKER_COMPOSE_FILE)

# Declares stack-level env vars upstream's compose file does not expose. Always
# passed: with no override set every value falls back to upstream's default, so
# including it changes nothing until you set one.
STACK_COMPOSE_FILE ?= $(PROJECT_PATH)/docker-compose.override.yml
DOCKER_COMPOSE_ARGS += --file $(STACK_COMPOSE_FILE)


# Only pass the env file once generated, since compose errors on a missing
# --env-file. This MUST stay recursively expanded ('=', not ':=') and must not
# use ifeq/wildcard: those resolve at parse time, when a first run has no env
# file yet, which would silently start every service on upstream's default
# passwords. Recipe-time expansion sees the file that langfuse/env just wrote.
DOCKER_COMPOSE_ENV_ARG = $(shell [ -f "$(LANGFUSE_ENV_FILE)" ] && echo "--env-file $(LANGFUSE_ENV_FILE)")

DOCKER_COMPOSE = docker compose $(DOCKER_COMPOSE_ARGS) $(DOCKER_COMPOSE_ENV_ARG)

DOCKER_COMPOSE_UP_ARGS ?=
DOCKER_COMPOSE_UP_ARGS += --detach
DOCKER_COMPOSE_UP_ARGS += --remove-orphans

# Set FOLLOW=false for a one-shot log dump, e.g. in CI where tailing would hang
FOLLOW ?= true
TAIL ?= 100
DOCKER_COMPOSE_LOGS_ARGS ?=
DOCKER_COMPOSE_LOGS_ARGS += --tail $(TAIL)
ifeq ($(FOLLOW),true)
DOCKER_COMPOSE_LOGS_ARGS += --follow
endif

# Verify the Docker daemon is reachable and the compose plugin is installed.
# Split from docker/check so 'make check' works before anything is cloned.
docker/daemon:
	@# On Linux the usual failure is not a stopped daemon but a user outside the
	@# 'docker' group, so tell the two apart rather than sending them to restart it.
	@if ! out="$$(docker info 2>&1)"; then \
		case "$$out" in \
			*"permission denied"*) \
				echo "[ERROR] No permission to use the Docker daemon. Add yourself to the 'docker'"; \
				echo "[ERROR] group (sudo usermod -aG docker \$$USER), then log out and back in." ;; \
			*) echo "[ERROR] Docker daemon is not running." ;; \
		esac; \
		exit 1; \
	fi
	@docker compose version > /dev/null 2>&1 || (echo "[ERROR] docker compose plugin is not installed." && exit 1)
.PHONY: docker/daemon

# Verify Docker is usable and the upstream compose file exists
docker/check: docker/daemon
	@if [ ! -f "$(DOCKER_COMPOSE_FILE)" ]; then \
		echo "[ERROR] Compose file '$(DOCKER_COMPOSE_FILE)' not found. Run 'make langfuse/clone'." && exit 1; \
	fi
.PHONY: docker/check

# Create and start compose services, restarting any that are stopped
docker/up: docker/check
	@if [ ! -f "$(LANGFUSE_ENV_FILE)" ]; then \
		echo "[ERROR] Env file '$(LANGFUSE_ENV_FILE)' not found. Run 'make langfuse/env'." && exit 1; \
	fi
	@echo "[INFO] Creating and starting '$(DOCKER_COMPOSE_PROJECT)' compose services."
	@# Also restarts stopped containers in place and recreates any whose config
	@# changed, so a plain 'up' covers start and recreate as well.
	@$(DOCKER_COMPOSE) up $(DOCKER_COMPOSE_UP_ARGS) $(SERVICE)
.PHONY: docker/up

# Remove compose containers and networks, preserving volumes
docker/down: docker/check
	@echo "[INFO] Removing '$(DOCKER_COMPOSE_PROJECT)' compose containers."
	@$(DOCKER_COMPOSE) down --remove-orphans
.PHONY: docker/down

## Show compose service status, including stopped containers
docker/ps: docker/check
	@$(DOCKER_COMPOSE) ps --all $(SERVICE)
.PHONY: docker/ps

## Tail compose service logs
docker/logs: docker/check
	@$(DOCKER_COMPOSE) logs $(DOCKER_COMPOSE_LOGS_ARGS) $(SERVICE)
.PHONY: docker/logs

## Remove compose containers, networks and volumes (prompts first)
docker/clean:
	@# Every "did not delete" path exits non-zero. 'clean' depends on this target
	@# and deletes .env afterwards, and .env holds the passwords baked into the
	@# volumes -- so volumes that survive without it are locked out for good.
	@if ! docker info > /dev/null 2>&1; then \
		echo "[ERROR] Docker daemon is not running, so volumes cannot be removed."; \
		echo "[ERROR] Start Docker and re-run."; \
		exit 1; \
	fi; \
	if [ ! -f "$(DOCKER_COMPOSE_FILE)" ]; then \
		if [ -n "$$(docker volume ls --quiet --filter label=com.docker.compose.project=$(DOCKER_COMPOSE_PROJECT))" ]; then \
			echo "[ERROR] Volumes for '$(DOCKER_COMPOSE_PROJECT)' exist but the compose file is missing."; \
			echo "[ERROR] Run 'make langfuse/clone' and re-run."; \
			exit 1; \
		fi; \
		exit 0; \
	fi; \
	if [ "$(FORCE)" != "true" ]; then \
		echo "[WARN] This permanently deletes all langfuse volumes (traces, users, API keys)."; \
		printf "[WARN] Continue? [y/N] "; \
		reply=""; \
		if [ -t 0 ]; then \
			read -r reply || reply=""; \
		elif read -r reply; then \
			:; \
		elif { read -r reply < /dev/tty; } 2>/dev/null; then \
			:; \
		else \
			echo; \
			echo "[ERROR] Refusing to delete volumes without confirmation. Re-run with FORCE=true."; \
			exit 1; \
		fi; \
		echo; \
		case "$$reply" in [yY]*) ;; *) echo "[INFO] Aborted."; exit 1 ;; esac; \
	fi; \
	echo "[INFO] Removing '$(DOCKER_COMPOSE_PROJECT)' compose containers and volumes."; \
	$(DOCKER_COMPOSE) down --remove-orphans --volumes
.PHONY: docker/clean

#-------------------------------------------------------------------------------
# backup
#-------------------------------------------------------------------------------

# Timestamped by default so successive backups never overwrite each other.
# ':=' is required: a recursive '=' would re-run `date` on every reference and a
# backup spanning a second boundary would scatter across two directories.
BACKUP_PATH ?= $(PROJECT_PATH)/backups
BACKUP_STAMP := $(shell date -u +%Y%m%dT%H%M%SZ)
BACKUP_DEST ?= $(BACKUP_PATH)/$(BACKUP_STAMP)

# Provides tar/gzip for volume archiving; the minio image is distroless.
BACKUP_HELPER_IMAGE ?= docker.io/alpine:3

# Secrets that must travel with the data. ENCRYPTION_KEY decrypts stored LLM
# credentials; SALT verifies hashed Langfuse API keys. Restoring rows without
# the values they were written under leaves them permanently unusable, so
# langfuse/restore reinstates these from the backup.
#
# Datastore passwords are deliberately NOT reinstated. A reprovisioned stack
# initialised its postgres/clickhouse/minio volumes from the *current* env file,
# so the live passwords are the ones those volumes accept; overwriting them with
# the backup's would lock the restore out of the very databases it writes to.
LANGFUSE_DATA_BOUND_SECRETS ?= ENCRYPTION_KEY SALT

# ClickHouse tables that hold rows of their own: everything except views,
# materialized views and the migration ledger. Used by both backup and restore.
CLICKHOUSE_DATA_TABLES_QUERY = SELECT name FROM system.tables \
	WHERE database = currentDatabase() AND NOT is_temporary \
	AND engine NOT IN ('View', 'MaterializedView', 'LiveView', 'WindowView') \
	AND name != 'schema_migrations'
CLICKHOUSE_MV_QUERY = SELECT name FROM system.tables \
	WHERE database = currentDatabase() AND engine = 'MaterializedView'

## Back up datastores and the encryption key
langfuse/backup: docker/check
	@if [ ! -f "$(LANGFUSE_ENV_FILE)" ]; then \
		echo "[ERROR] Env file '$(LANGFUSE_ENV_FILE)' not found. Nothing to back up." && exit 1; \
	fi
	@echo "[INFO] Backing up to '$(BACKUP_DEST)'."
	@mkdir -p "$(BACKUP_DEST)"
	@chmod 700 "$(BACKUP_DEST)"
	@# The env file holds ENCRYPTION_KEY. Without it a restored database cannot
	@# decrypt API keys or LLM credentials, so it travels with the dumps.
	@echo "[INFO] Saving env file."
	@cp "$(LANGFUSE_ENV_FILE)" "$(BACKUP_DEST)/env"
	@echo "[INFO] Dumping postgres."
	@$(DOCKER_COMPOSE) exec --no-TTY postgres \
		pg_dump --username "$(LANGFUSE_POSTGRES_USER)" --dbname "$(LANGFUSE_POSTGRES_DB)" --clean --if-exists \
		| gzip > "$(BACKUP_DEST)/postgres.sql.gz"
	@echo "[INFO] Dumping clickhouse."
	@# Only tables that hold data. Views have no rows of their own, a materialized
	@# view's rows live in its target table (dumped separately), and
	@# schema_migrations is recreated by the fresh stack a restore lands on --
	@# inserting any of these back would fail or duplicate rows.
	@ch_password="$$(grep -E '^CLICKHOUSE_PASSWORD=' "$(LANGFUSE_ENV_FILE)" | cut -d= -f2-)"; \
	tables="$$($(DOCKER_COMPOSE) exec --no-TTY clickhouse clickhouse-client \
		--user "$(LANGFUSE_CLICKHOUSE_USER)" --password "$$ch_password" \
		--database "$(LANGFUSE_CLICKHOUSE_DB)" \
		--query "$(CLICKHOUSE_DATA_TABLES_QUERY)" | tr -d '\r')"; \
	for table in $$tables; do \
		echo "[INFO]   clickhouse table '$$table'."; \
		$(DOCKER_COMPOSE) exec --no-TTY clickhouse clickhouse-client \
			--user "$(LANGFUSE_CLICKHOUSE_USER)" --password "$$ch_password" \
			--database "$(LANGFUSE_CLICKHOUSE_DB)" \
			--query "SELECT * FROM \`$$table\` FORMAT Native" \
			| gzip > "$(BACKUP_DEST)/clickhouse-$$table.native.gz"; \
	done
	@# The minio image is distroless (no tar/gzip), so archive its volume with a
	@# helper container instead of shelling into the service.
	@echo "[INFO] Archiving minio volume."
	@docker run --rm \
		--volume "$(DOCKER_COMPOSE_PROJECT)_langfuse_minio_data:/data:ro" \
		$(BACKUP_HELPER_IMAGE) tar -czf - -C /data . > "$(BACKUP_DEST)/minio.tar.gz"
	@echo "[INFO] Backup complete: '$(BACKUP_DEST)'."
	@ls -lh "$(BACKUP_DEST)"
.PHONY: langfuse/backup

## Restore datastores from BACKUP_DEST
langfuse/restore: docker/check
	$(call assert-set,BACKUP_DEST)
	@if [ ! -d "$(BACKUP_DEST)" ]; then \
		echo "[ERROR] Backup directory '$(BACKUP_DEST)' not found."; \
		echo "[ERROR] Pass one explicitly, e.g. BACKUP_DEST=$(BACKUP_PATH)/<stamp> make langfuse/restore."; \
		echo "[ERROR] Available: $$(ls -1 "$(BACKUP_PATH)" 2>/dev/null | tr '\n' ' ' || echo none)"; \
		exit 1; \
	fi
	@if [ "$(FORCE)" != "true" ]; then \
		echo "[WARN] This overwrites the current langfuse database contents."; \
		printf "[WARN] Restore from '$(BACKUP_DEST)'? [y/N] "; \
		reply=""; \
		if [ -t 0 ]; then \
			read -r reply || reply=""; \
		elif read -r reply; then \
			:; \
		elif { read -r reply < /dev/tty; } 2>/dev/null; then \
			:; \
		else \
			echo; \
			echo "[ERROR] Refusing to overwrite data without confirmation. Re-run with FORCE=true."; \
			exit 1; \
		fi; \
		echo; \
		case "$$reply" in [yY]*) ;; *) echo "[INFO] Aborted."; exit 1 ;; esac; \
	fi
	@# Reinstate the secrets the backed-up rows were encrypted and hashed under.
	@# Without this a reprovisioned stack restores data it can never decrypt,
	@# because langfuse/env generated a fresh ENCRYPTION_KEY and SALT.
	@if [ ! -f "$(BACKUP_DEST)/env" ]; then \
		echo "[WARN] Backup has no env file; cannot verify ENCRYPTION_KEY matches."; \
		echo "[WARN] Encrypted values in the restored data may be unreadable."; \
	else \
		changed=""; \
		for secret in $(LANGFUSE_DATA_BOUND_SECRETS); do \
			backed_up="$$(grep -E "^$$secret=" "$(BACKUP_DEST)/env" | cut -d= -f2-)"; \
			live="$$(grep -E "^$$secret=" "$(LANGFUSE_ENV_FILE)" | cut -d= -f2- || true)"; \
			if [ -z "$$backed_up" ]; then \
				echo "[WARN] Backup env has no $$secret; leaving the live value in place."; \
			elif [ "$$backed_up" != "$$live" ]; then \
				changed="$$changed $$secret"; \
			fi; \
		done; \
		if [ -n "$$changed" ]; then \
			echo "[INFO] Reinstating from backup:$$changed"; \
			cp "$(LANGFUSE_ENV_FILE)" "$(LANGFUSE_ENV_FILE).bak"; \
			echo "[INFO] Current env file backed up to '$(LANGFUSE_ENV_FILE).bak'."; \
			for secret in $$changed; do \
				backed_up="$$(grep -E "^$$secret=" "$(BACKUP_DEST)/env" | cut -d= -f2-)"; \
				tmp="$$(mktemp)"; \
				awk -v key="$$secret" -v val="$$backed_up" \
					'BEGIN{FS=OFS="="} $$1==key{print key "=" val; found=1; next} {print} END{if(!found) print key "=" val}' \
					"$(LANGFUSE_ENV_FILE)" > "$$tmp"; \
				cat "$$tmp" > "$(LANGFUSE_ENV_FILE)"; \
				rm -f "$$tmp"; \
			done; \
			chmod 600 "$(LANGFUSE_ENV_FILE)"; \
		else \
			echo "[INFO] Data-bound secrets already match the backup."; \
		fi; \
	fi
	@# The app services must be down for the whole datastore rewrite. Left running,
	@# the web container's prisma migrations race the dump's DROP/CREATE and leave
	@# a failed-migration row that crash-loops the container (prisma P3009).
	@echo "[INFO] Stopping app services for the duration of the restore."
	@$(DOCKER_COMPOSE) stop $(LANGFUSE_APP_SERVICES) > /dev/null
	@echo "[INFO] Restoring postgres."
	@# ON_ERROR_STOP: without it psql reports success even when the restore failed.
	@gunzip -c "$(BACKUP_DEST)/postgres.sql.gz" \
		| $(DOCKER_COMPOSE) exec --no-TTY postgres \
			psql --quiet --set ON_ERROR_STOP=on \
				--username "$(LANGFUSE_POSTGRES_USER)" --dbname "$(LANGFUSE_POSTGRES_DB)" > /dev/null
	@# Dumps load with INSERT, which appends. Restore into a clean stack or rows
	@# duplicate; see the note in the README before restoring over live data.
	@echo "[INFO] Restoring clickhouse."
	@# Materialized views are detached for the load: every dumped table is restored
	@# directly, so an MV firing on its source would write its target's rows twice.
	@# The EXIT trap reattaches them even if a load fails; a detach that is somehow
	@# left behind is also undone by a clickhouse restart, since it is not PERMANENT.
	@# Dumps of views, MVs or schema_migrations (written by older backups) are
	@# skipped, since inserting into them fails or duplicates. Empty dumps are
	@# skipped too: clickhouse rejects an INSERT with no rows (NO_DATA_TO_INSERT).
	@ch_password="$$(grep -E '^CLICKHOUSE_PASSWORD=' "$(LANGFUSE_ENV_FILE)" | cut -d= -f2-)"; \
	ch() { \
		$(DOCKER_COMPOSE) exec --no-TTY clickhouse clickhouse-client \
			--user "$(LANGFUSE_CLICKHOUSE_USER)" --password "$$ch_password" \
			--database "$(LANGFUSE_CLICKHOUSE_DB)" --query "$$1"; \
	}; \
	data_tables=" $$(ch "$(CLICKHOUSE_DATA_TABLES_QUERY)" | tr -d '\r' | tr '\n' ' ') "; \
	mvs="$$(ch "$(CLICKHOUSE_MV_QUERY)" | tr -d '\r')"; \
	reattach() { for mv in $$mvs; do ch "ATTACH TABLE \`$$mv\`" || echo "[WARN] Could not reattach '$$mv'; restart clickhouse."; done; }; \
	trap reattach EXIT; \
	for mv in $$mvs; do ch "DETACH TABLE \`$$mv\`"; done; \
	for dump in "$(BACKUP_DEST)"/clickhouse-*.native.gz; do \
		[ -e "$$dump" ] || continue; \
		table="$$(basename "$$dump" .native.gz)"; \
		table="$${table#clickhouse-}"; \
		case "$$data_tables" in \
			*" $$table "*) ;; \
			*) echo "[INFO]   skipping '$$table' (not a data table in this stack)."; continue ;; \
		esac; \
		echo "[INFO]   clickhouse table '$$table'."; \
		if [ "$$({ gunzip -c "$$dump" || true; } | head -c 1 | wc -c)" -eq 0 ]; then \
			echo "[INFO]   skipping '$$table' (empty)."; continue; \
		fi; \
		gunzip -c "$$dump" | $(DOCKER_COMPOSE) exec --no-TTY clickhouse clickhouse-client \
			--user "$(LANGFUSE_CLICKHOUSE_USER)" --password "$$ch_password" \
			--database "$(LANGFUSE_CLICKHOUSE_DB)" \
			--query "INSERT INTO \`$$table\` FORMAT Native"; \
	done
	@# Minio must be stopped while its volume is rewritten, or the running server
	@# will not see the replaced objects and may overwrite them.
	@echo "[INFO] Restoring minio volume."
	@$(DOCKER_COMPOSE) stop minio > /dev/null
	@docker run --rm --interactive \
		--volume "$(DOCKER_COMPOSE_PROJECT)_langfuse_minio_data:/data" \
		$(BACKUP_HELPER_IMAGE) sh -c 'find /data -mindepth 1 -delete && tar -xzf - -C /data' \
		< "$(BACKUP_DEST)/minio.tar.gz"
	@$(DOCKER_COMPOSE) start minio > /dev/null
	@# The web and worker containers still hold the pre-restore ENCRYPTION_KEY in
	@# their environment, so recreate them to pick up the reinstated values.
	@echo "[INFO] Recreating app services to pick up restored secrets."
	@$(DOCKER_COMPOSE) up $(DOCKER_COMPOSE_UP_ARGS) --force-recreate $(LANGFUSE_APP_SERVICES) > /dev/null
	@echo "[INFO] Restore complete."
.PHONY: langfuse/restore

#-------------------------------------------------------------------------------
# dev
#-------------------------------------------------------------------------------

# Bootstrap and trace/project both run last and are no-ops unless their
# LANGFUSE_INIT_* / LANGFUSE_TRACE_* variables are configured, so a plain
# 'make dev/up' stays silent for anyone who is not tracing.
#
# trace/install is included unconditionally: it is a no-op unless the env file has
# a key pair AND the installed plugin is not already carrying it, so a plain
# 'make dev/up' neither installs anything unasked nor re-runs work already done.
## Clone, configure and start Langfuse (default goal)
dev/up: BOOTSTRAP_OPTIONAL = true
dev/up: TRACE_OPTIONAL = true
dev/up: langfuse/clone langfuse/env docker/up langfuse/wait langfuse/bootstrap trace/install
.PHONY: dev/up

# Alias for symmetry with dev/up. 'compose down' acts on the whole project, so
# it stops every service regardless of which compose files were passed.
## Stop everything for the day, keeping all data
dev/down: docker/down
.PHONY: dev/down

#-------------------------------------------------------------------------------
# clean
#-------------------------------------------------------------------------------

## Remove compose state, langfuse source and .env (keeps backups)
clean: docker/clean
	@if [ -d "$(LANGFUSE_SRC_PATH)" ]; then \
		echo "[INFO] Removing langfuse source found at '$(LANGFUSE_SRC_PATH)'."; \
		rm -rf "$(LANGFUSE_SRC_PATH)"; \
	fi
	@if [ -f "$(LANGFUSE_ENV_FILE)" ]; then \
		echo "[INFO] Removing env file '$(LANGFUSE_ENV_FILE)' (copy kept as '$(LANGFUSE_ENV_FILE).bak')."; \
		cp -p "$(LANGFUSE_ENV_FILE)" "$(LANGFUSE_ENV_FILE).bak"; \
		rm -f "$(LANGFUSE_ENV_FILE)"; \
	fi
	@# Backups are deliberately preserved; removing them would defeat the point.
	@if [ -d "$(BACKUP_PATH)" ] && [ -n "$$(ls -A "$(BACKUP_PATH)" 2>/dev/null)" ]; then \
		echo "[INFO] Preserving backups in '$(BACKUP_PATH)'."; \
	fi
.PHONY: clean
