SHELL := /usr/bin/env bash

STACK ?= all
ORCHESTRATOR := ./scripts/orchestrator.sh

.PHONY: help deps fmt validate init plan apply output destroy

help:
	@$(ORCHESTRATOR) help

deps:
	@$(ORCHESTRATOR) deps

fmt:
	@$(ORCHESTRATOR) fmt $(STACK)

validate:
	@$(ORCHESTRATOR) validate $(STACK)

init:
	@$(ORCHESTRATOR) init $(STACK)

plan:
	@$(ORCHESTRATOR) plan $(STACK)

apply:
	@$(ORCHESTRATOR) apply $(STACK)

output:
	@$(ORCHESTRATOR) output $(STACK)

destroy:
	@$(ORCHESTRATOR) destroy $(STACK)

fmt-% validate-% init-% plan-% apply-% output-%:
	@target="$@"; action="$${target%%-*}"; stack="$${target#*-}"; $(ORCHESTRATOR) "$$action" "$$stack"
