SHELL := /bin/bash
.DEFAULT_GOAL := help

# =============================================================================
# Root Makefile - deploy the sample apps in this repo to LocalStack
# =============================================================================
#
# This Makefile is just a router: it forwards targets to the per-app Makefile
# of whichever sample app is selected via APP=<name>. Each app directory owns
# its own build/deploy/invoke logic; see that Makefile for app-specific
# details and variables (e.g. `make -C "Industry Solutions/.../FraudDetection" help`).
#
# Usage:
#   make list-apps
#   make deploy APP=fraud-detection
#   make invoke APP=fraud-detection AMOUNT=6500
#   make fraud-detection             # shorthand for: make deploy APP=fraud-detection
#
# To add a new sample app: register its directory below and give it a
# Makefile that implements the same target names (help, build, deploy,
# invoke, logs, status, clean, delete).
# =============================================================================

APPS := fraud-detection

fraud-detection_DIR := Industry Solutions/Financial Services (FSI)/FraudDetection
fraud-detection_DESC := Bedrock AgentCore fraud-detection workflow (Lambda Durable Functions)

# App to operate on for the forwarded targets below.
APP ?= fraud-detection

.PHONY: help list-apps check start stop install-stripe-extension build deploy invoke callback executions logs outputs clean delete $(APPS)

help: ## Show this help
	@echo "Sample apps in this repo, deployable to LocalStack:"
	@echo ""
	@$(MAKE) --no-print-directory list-apps
	@echo ""
	@echo "Targets below are forwarded to the selected app's Makefile (default APP=$(APP)):"
	@echo "  check start stop install-stripe-extension build deploy invoke callback executions logs outputs clean delete"
	@echo "Run 'make -C \"\$$(make print-dir APP=<app>)\" help' for that app's own target descriptions."
	@echo ""
	@echo "Examples:"
	@echo "  make deploy APP=fraud-detection"
	@echo "  make fraud-detection             # shorthand for: make deploy APP=fraud-detection"

list-apps: ## List sample apps registered for LocalStack deployment
	@for a in $(APPS); do \
		dir="$$($(MAKE) --no-print-directory print-dir APP=$$a)"; \
		desc="$$($(MAKE) --no-print-directory print-desc APP=$$a)"; \
		printf "  \033[36m%-18s\033[0m %s\n" "$$a" "$$desc"; \
	done

print-dir:
	@echo "$($(APP)_DIR)"

print-desc:
	@echo "$($(APP)_DESC)"

check start stop install-stripe-extension build deploy invoke callback executions logs outputs clean delete:
	@dir="$($(APP)_DIR)"; \
	if [ -z "$$dir" ]; then \
		echo "Unknown APP '$(APP)'. Run 'make list-apps' to see available apps." >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory -C "$$dir" $@

# Per-app shorthand: `make <app-name>` deploys that app (e.g. `make fraud-detection`).
$(APPS):
	@$(MAKE) --no-print-directory deploy APP=$@
