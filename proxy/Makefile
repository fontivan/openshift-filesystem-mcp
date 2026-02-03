# SPDX-License-Identifier: Apache-2.0
# Proxy (Python MCP proxy) – build and push container image
export SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

# Subproject root (proxy dir); repo root is parent
export PROXY_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
export ROOT_DIR ?= $(shell dirname $(PROXY_DIR))

# Image settings (override from root Makefile or env)
QUAY_WORKSPACE ?= $(USER)
VERSION ?= $(shell git -C $(ROOT_DIR) describe --tags --always --dirty 2>/dev/null || echo "latest")
IMG_PROXY ?= quay.io/$(QUAY_WORKSPACE)/openshift-filesystem-mcp-proxy:$(VERSION)
CONTAINER_ENGINE ?= podman
PLATFORM ?= linux/amd64
# For hadolint when invoked from root (root provides venv)
BIN ?= $(ROOT_DIR)/venv/bin

.PHONY: container-build container-push hadolint help

## container-build: Build the proxy container image
container-build:
	$(CONTAINER_ENGINE) build -f $(PROXY_DIR)/Containerfile --platform $(PLATFORM) -t $(IMG_PROXY) $(PROXY_DIR)

## container-push: Push the proxy container image to registry
container-push:
	$(CONTAINER_ENGINE) push $(IMG_PROXY)

## hadolint: Lint proxy Containerfile (run from repo root after make venv)
hadolint:
	$(BIN)/hadolint $(PROXY_DIR)/Containerfile

## help: Show proxy make targets
help:
	@echo "Proxy targets:"
	@sed -n 's/^##//p' $(MAKEFILE_LIST) | column -t -s ':' | sed -e 's/^/ /'
