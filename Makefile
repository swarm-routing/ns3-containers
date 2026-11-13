# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: GPL-2.0-only
#
# ns3-containers: the org's standard targets (swarm-routing/.github#11). Every org
# repo has these same target names, with this repo's own commands behind them;
# `org-sync check` verifies the names are present, never the recipes. Add
# repo-only targets at the end. `make help` lists everything with a `## ` note.

NS3_IMAGE ?= ghcr.io/swarm-routing/ns3-dev:latest-debug
PLATFORM  ?=
# container kind: the image's Dockerfile and its build arguments
DOCKERFILE ?= docker/Dockerfile
BUILD_ARGS ?=
# The org tooling (check-headers.py, org-sync): a shallow clone, refreshed to ORG_REF.
ORG_DIR   ?= $(HOME)/.cache/swarm-routing/dotgithub
ORG_REF   ?= main

.DEFAULT_GOAL := help
.PHONY: help build test lint format check clean shell ci headers org-sync-check org-tools dist

help: ## list the targets
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## build what this repo ships
	docker buildx build --load $(if $(PLATFORM),--platform $(PLATFORM)) -f $(DOCKERFILE) $(BUILD_ARGS) -t local/$(notdir $(CURDIR)):dev .

test: ## the fast tests CI runs on every PR
	python3 -m unittest discover -s tools
	$(MAKE) build
	test/run.sh local/$(notdir $(CURDIR)):dev

lint: ## static checks, no changes
	shellcheck $$(git ls-files "*.sh") && actionlint

format: ## apply the formatters
	@echo "make format: nothing to do in this repo (kind container)"

clean: ## remove build outputs
	docker image rm -f local/$(notdir $(CURDIR)):dev

shell: ## an interactive shell in the dev image with this repo at /src
	@command -v docker >/dev/null || { echo "make shell: docker not found (Docker Desktop, Colima, or docker.io)" >&2; exit 127; }
	docker run --rm -it -v "$(CURDIR):/src" -w /src $(if $(PLATFORM),--platform $(PLATFORM)) $(NS3_IMAGE) bash

org-tools:  # the same templates CI checks against: refreshed to ORG_REF every time
	@[ -d "$(ORG_DIR)/.git" ] || { git init -q "$(ORG_DIR)" && git -C "$(ORG_DIR)" remote add origin https://github.com/swarm-routing/.github; }
	@git -C "$(ORG_DIR)" fetch -q --depth 1 origin $(ORG_REF) && git -C "$(ORG_DIR)" checkout -q --detach FETCH_HEAD

headers: org-tools ## licence headers (org rule 1)
	python3 -I "$(ORG_DIR)/tools/checks/check-headers.py" --dual docker/ --dual test/smoke.sh --dual test/run.sh --dual test/structure.sh --dual test/integration.sh --dual test/profile.sh --dual test/unit.sh --dual test/downstream.sh --dual tools/ --dual .github/workflows/ .

org-sync-check: org-tools ## org-managed files match the org templates
	python3 -I "$(ORG_DIR)/tools/org-sync/org_sync.py" check .

check: lint test headers org-sync-check ## everything CI gates on

ci: check ## exactly what CI runs

RELEASE_VERSION ?= $(shell sed -n 's/^version = "\(.*\)"/\1/p' .cz.toml)
dist: ## the release asset in dist/: the image pipeline's source tarball, checked
	tools/release/dist.sh $(RELEASE_VERSION) dist
