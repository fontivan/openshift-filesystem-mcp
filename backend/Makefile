# SPDX-License-Identifier: Apache-2.0
# Backend (Node.js MCP server) – build and push container image
export SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

# Subproject root (backend dir); repo root is parent
export BACKEND_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
export ROOT_DIR ?= $(shell dirname $(BACKEND_DIR))

# Image settings (override from root Makefile or env)
QUAY_WORKSPACE ?= $(USER)
VERSION ?= $(shell git -C $(ROOT_DIR) describe --tags --always --dirty 2>/dev/null || echo "latest")
IMG_BACKEND ?= quay.io/$(QUAY_WORKSPACE)/openshift-filesystem-mcp-backend:$(VERSION)
CONTAINER_ENGINE ?= podman
PLATFORM ?= linux/amd64
# For hadolint when invoked from root (root provides venv)
BIN ?= $(ROOT_DIR)/venv/bin

.PHONY: container-build container-push hadolint help

## container-build: Build the backend container image
container-build:
	$(CONTAINER_ENGINE) build -f $(BACKEND_DIR)/Containerfile --platform $(PLATFORM) -t $(IMG_BACKEND) $(BACKEND_DIR)

## container-push: Push the backend container image to registry
container-push:
	$(CONTAINER_ENGINE) push $(IMG_BACKEND)

## hadolint: Lint backend Containerfile (run from repo root after make venv)
hadolint:
	$(BIN)/hadolint $(BACKEND_DIR)/Containerfile

## help: Show backend make targets
help:
	@echo "Backend targets:"
	@sed -n 's/^##//p' $(MAKEFILE_LIST) | column -t -s ':' | sed -e 's/^/ /'
