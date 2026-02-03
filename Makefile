# SPDX-License-Identifier: Apache-2.0
# Root Makefile: common settings, venv/lint, deploy; delegates container build/push to backend/ and proxy/
# venv python integration derived from https://venthur.de/2021-03-31-python-makefiles.html
export SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Common variables (exported to subproject Makefiles when delegating)
# ------------------------------------------------------------------------------
export ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

# Host python used to setup venv
export PY ?= python3
export VENV := $(ROOT_DIR)/venv
export BIN := $(VENV)/bin

# Image settings (backend/ and proxy/ Containerfiles; override QUAY_WORKSPACE to push elsewhere)
QUAY_WORKSPACE ?= $(USER)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "latest")
export IMG_BACKEND ?= quay.io/$(QUAY_WORKSPACE)/openshift-filesystem-mcp-backend:$(VERSION)
export IMG_PROXY ?= quay.io/$(QUAY_WORKSPACE)/openshift-filesystem-mcp-proxy:$(VERSION)
export CONTAINER_ENGINE ?= podman
export PLATFORM ?= linux/amd64

# Kustomize image names that deploy target will replace
KUSTOMIZE_IMAGE_BACKEND := quay.io/REPLACE_WITH_YOUR_USERNAME/openshift-filesystem-mcp-backend
KUSTOMIZE_IMAGE_PROXY := quay.io/REPLACE_WITH_YOUR_USERNAME/openshift-filesystem-mcp-proxy

# Staging dirs for /sys and /proc on hosts that don't have them (e.g. macOS)
LOCAL_MCP_HOST_DIR := $(ROOT_DIR)/.local-mcp-host

.PHONY: container-build container-push deploy undeploy deploy-local deploy-local-dirs undeploy-local
.PHONY: apply-scc grant-scc setup-registry-credentials help
.PHONY: venv yamllint hadolint mdlint lint clean

# ------------------------------------------------------------------------------
# Container build/push – delegate to subprojects
# ------------------------------------------------------------------------------

## container-build: Build both container images (backend + proxy)
container-build:
	$(MAKE) -C $(ROOT_DIR)/backend container-build
	$(MAKE) -C $(ROOT_DIR)/proxy container-build

## container-push: Push both container images to registry
container-push:
	$(MAKE) -C $(ROOT_DIR)/backend container-push
	$(MAKE) -C $(ROOT_DIR)/proxy container-push

# ------------------------------------------------------------------------------
# Deploy (OpenShift / kustomize)
# ------------------------------------------------------------------------------

## deploy: Deploy to OpenShift using kustomize (replaces both images; does not mutate deploy/)
deploy:
	@echo "Deploying openshift-filesystem-mcp to cluster..."
	@echo "Using backend: $(IMG_BACKEND), proxy: $(IMG_PROXY)"
	@mkdir -p $(ROOT_DIR)/.build && rm -rf $(ROOT_DIR)/.build/deploy && cp -r deploy $(ROOT_DIR)/.build/deploy
	cd $(ROOT_DIR)/.build/deploy && kustomize edit set image $(KUSTOMIZE_IMAGE_BACKEND)=$(IMG_BACKEND)
	cd $(ROOT_DIR)/.build/deploy && kustomize edit set image $(KUSTOMIZE_IMAGE_PROXY)=$(IMG_PROXY)
	kubectl apply -k $(ROOT_DIR)/.build/deploy/

## undeploy: Remove deployment from OpenShift
undeploy:
	kubectl delete -k deploy/ --ignore-not-found=true

## deploy-local-dirs: Create dummy content in .local-mcp-host for testing MCP (sys, proc, usr)
deploy-local-dirs:
	@mkdir -p $(LOCAL_MCP_HOST_DIR)/sys/kernel $(LOCAL_MCP_HOST_DIR)/sys/class/net \
		$(LOCAL_MCP_HOST_DIR)/proc $(LOCAL_MCP_HOST_DIR)/usr/share/containers
	@echo "# Dummy content for local MCP testing (see Makefile deploy-local-dirs)" > $(LOCAL_MCP_HOST_DIR)/README.txt
	@echo "Linux version 5.0.0-dummy (local-mcp-host) #1 SMP Thu Jan 1 00:00:00 UTC 1970" > $(LOCAL_MCP_HOST_DIR)/proc/version
	@echo "0.00 0.00" > $(LOCAL_MCP_HOST_DIR)/proc/uptime
	@echo "processor	: 0\nmodel name	: Dummy CPU (local-mcp-host)\ncpu MHz		: 2400.000" > $(LOCAL_MCP_HOST_DIR)/proc/cpuinfo
	@echo "MemTotal:        8000000 kB\nMemFree:         4000000 kB\nMemAvailable:    6000000 kB" > $(LOCAL_MCP_HOST_DIR)/proc/meminfo
	@mkdir -p $(LOCAL_MCP_HOST_DIR)/proc/sys/kernel
	@echo "local-mcp-host-dummy" > $(LOCAL_MCP_HOST_DIR)/proc/sys/kernel/hostname
	@echo "5.0.0-dummy" > $(LOCAL_MCP_HOST_DIR)/sys/kernel/osrelease
	@echo "local-mcp-host" > $(LOCAL_MCP_HOST_DIR)/sys/kernel/version
	@echo "Dummy content for MCP filesystem testing. Use 'make deploy-local' to run the server." >> $(LOCAL_MCP_HOST_DIR)/README.txt
	@echo "Created dummy content in $(LOCAL_MCP_HOST_DIR)/ (sys/, proc/, README.txt)"

## deploy-local: Build and run backend locally (no proxy; /etc, /sys, /proc, /usr read-only)
deploy-local: container-build deploy-local-dirs
	@SYS_PATH=/sys; [ -d /sys ] || SYS_PATH=$(LOCAL_MCP_HOST_DIR)/sys; \
	PROC_PATH=/proc; [ -d /proc ] || PROC_PATH=$(LOCAL_MCP_HOST_DIR)/proc; \
	USR_PATH=/usr; [ -d /usr ] || USR_PATH=$(LOCAL_MCP_HOST_DIR)/usr; \
	echo "MCP server at http://localhost:8080 (Ctrl+C to stop)"; \
	$(CONTAINER_ENGINE) run --rm -p 8080:8081 \
		-v /etc:/host/etc:ro -v $$SYS_PATH:/host/sys:ro -v $$PROC_PATH:/host/proc:ro -v $$USR_PATH:/host/usr:ro \
		$(IMG_BACKEND)

## undeploy-local: Stop the locally running MCP server container (if run in background)
undeploy-local:
	@container_id=$$($(CONTAINER_ENGINE) ps -q -f "ancestor=$(IMG_BACKEND)" 2>/dev/null); \
	if [ -n "$$container_id" ]; then \
		echo "$$container_id" | xargs $(CONTAINER_ENGINE) stop; \
		echo "Stopped local MCP server"; \
	else \
		echo "No local MCP server running"; \
	fi

## apply-scc: Create the custom hostpath-readonly SCC in the cluster (run once, cluster-admin)
apply-scc:
	kubectl apply -f deploy/scc-hostpath-readonly.yaml
	@echo "SCC hostpath-readonly created. Run 'make grant-scc' to grant it to the ServiceAccount."

## grant-scc: Grant hostpath-readonly SCC to the ServiceAccount (required for host path mounts)
grant-scc:
	oc adm policy add-scc-to-user hostpath-readonly -z openshift-filesystem-mcp -n openshift-filesystem-mcp
	@echo "SCC granted. Run 'make deploy' to deploy."

## setup-registry-credentials: Create registry credentials from OpenShift pull-secret (for registry.redhat.io)
setup-registry-credentials:
	@echo "Creating registry-credentials secret from OpenShift pull-secret..."
	@kubectl create secret generic registry-credentials \
		--from-literal=.dockerconfigjson="$$(kubectl get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)" \
		--type=kubernetes.io/dockerconfigjson \
	-n openshift-filesystem-mcp \
	--dry-run=client -o yaml | kubectl apply -f -
	@echo "Registry credentials configured successfully"

# ------------------------------------------------------------------------------
# Venv and lint (root-level; hadolint delegates to backend and proxy)
# ------------------------------------------------------------------------------

venv: $(VENV)

# Create Python virtual environment if missing or when requirements.txt changes
$(VENV): $(ROOT_DIR)/requirements.txt
	$(PY) -m venv $(VENV)
	$(BIN)/pip install --upgrade -r $(ROOT_DIR)/requirements.txt
	touch $(VENV)

## lint: Run all linters (yamllint, hadolint, mdlint)
lint: yamllint hadolint mdlint
	@echo "All linters passed."

## yamllint: Lint YAML files (deploy/, .yamllint.yaml; config in .yamllint.yaml)
yamllint: venv
	$(BIN)/yamllint -c $(ROOT_DIR)/.yamllint.yaml .

## hadolint: Lint Containerfiles in backend/ and proxy/
hadolint: venv
	$(MAKE) -C $(ROOT_DIR)/backend hadolint BIN=$(BIN)
	$(MAKE) -C $(ROOT_DIR)/proxy hadolint BIN=$(BIN)

## mdlint: Lint Markdown files (config: .pymarkdownlnt.json, MD013 disabled)
mdlint: venv
	$(BIN)/pymarkdownlnt -c $(ROOT_DIR)/.pymarkdownlnt.json scan $(shell find $(ROOT_DIR) \( -path $(ROOT_DIR)/venv -o -path '*/node_modules' \) -prune -o -type f -name "*.md" -print)

## clean: Remove venv and Python cache
clean:
	rm -rf $(VENV)
	find $(ROOT_DIR) -type f -name '*.pyc' -delete
	find $(ROOT_DIR) -type d -name __pycache__ -delete

## help: Show this help message
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@sed -n 's/^##//p' $(MAKEFILE_LIST) | column -t -s ':' | sed -e 's/^/ /'
	@echo ""
	@echo "Variables:"
	@echo "  IMG_BACKEND            Backend image (default: quay.io/\$$(USER)/openshift-filesystem-mcp-backend:\$$(VERSION))"
	@echo "  IMG_PROXY              Proxy image (default: quay.io/\$$(USER)/openshift-filesystem-mcp-proxy:\$$(VERSION))"
	@echo "  CONTAINER_ENGINE       Container engine (default: podman, can use docker)"
	@echo "  PLATFORM               Target platform for container build (default: linux/amd64)"
	@echo "  VERSION                Image tag (default: git describe or 'latest')"
	@echo ""
	@echo "Subprojects: backend/ and proxy/ have their own Makefiles. From repo root:"
	@echo "  make -C backend help    # backend-only targets"
	@echo "  make -C proxy help      # proxy-only targets"
	@echo ""
	@echo "Examples:"
	@echo "  make container-build                                                      # Build both images"
	@echo "  make container-push                                                       # Push both images"
	@echo "  make apply-scc grant-scc                                                   # Create hostpath-readonly SCC (run once)"
	@echo "  make deploy                                                               # Deploy to cluster"
	@echo "  make deploy-local                                                         # Build and run backend locally"
	@echo "  make undeploy-local                                                       # Stop the local MCP server"
	@echo "  make deploy-local-dirs                                                    # Create dummy content in .local-mcp-host/"
	@echo "  make lint                                                                # Run yamllint and hadolint"
	@echo ""
	@echo "Full workflow (apply SCC, grant to SA once, then build, push, deploy):"
	@echo "  make apply-scc grant-scc container-build container-push deploy"
