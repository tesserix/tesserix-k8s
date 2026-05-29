# tesserix-k8s — local sandbox bootstrap (POST `sandboxctl up`).
#
# You bring the kind sandbox up yourself, once:
#
#   sandboxctl up --with-cnpg --podman-disk 80 --podman-memory 12g
#
# Then this one command does ALL the local bootstrap on top of it — push the
# charts to the in-cluster Gitea and apply the app-of-apps (cnpg-operator ->
# local-infra shared datastores -> products) so Argo CD syncs everything:
#
#   make local-up
#
# It does NOT run `sandboxctl up` (that's slow/heavy and only needed once); it
# preflight-checks the sandbox is up and tells you to run it if not.

SHELL        := /bin/bash
LOCAL_ROOT   := charts/apps/local-root
APPLY        := $(LOCAL_ROOT)/apply-local.sh
CLEAN        := charts/apps/local-infra/clean-product.sh
# DEFAULT ALWAYS to the local sandbox kubeconfig. ':=' (not '?=') makes the
# Makefile IGNORE any ambient $KUBECONFIG (which may point at prod). Override
# intentionally with: make <target> KUBECONFIG=/path  (command-line wins).
KUBECONFIG   := $(HOME)/.sandboxctl/kubeconfig
export KUBECONFIG

# Extra flags forwarded to apply-local.sh, e.g. ARGS="--set products.devai-api.enabled=true"
ARGS ?=

.PHONY: local-up local-clean local-status local-doctor local-down local-help

local-up: ## Post-up bootstrap: push charts to Gitea + apply the app-of-apps (run AFTER 'sandboxctl up')
	@kubectl get ns argocd >/dev/null 2>&1 || { \
	  echo "✗ sandbox not up (no 'argocd' namespace via KUBECONFIG=$(KUBECONFIG))."; \
	  echo "  Bring it up once:  sandboxctl up --with-cnpg --podman-disk 80 --podman-memory 12g"; \
	  exit 1; }
	@kubectl get ns cnpg-system >/dev/null 2>&1 || \
	  echo "⚠ cnpg-system not found — shared Postgres needs the CNPG operator ('sandboxctl up --with-cnpg'). Continuing…"
	$(APPLY) $(ARGS)
	@echo
	@echo "Local stack syncing. Watch it:  make local-status"

local-clean: ## Reset ONE product's data: make local-clean PRODUCT=devai
	@test -n "$(PRODUCT)" || { echo "usage: make local-clean PRODUCT=<agentic-registry|devai|homechef|mark8ly|fanzone>"; exit 2; }
	$(CLEAN) $(PRODUCT)

local-status: ## Show the local app-of-apps + datastore health
	@kubectl -n argocd get applications -l app.kubernetes.io/part-of=local-root 2>/dev/null || echo "no local-root apps yet — run 'make local-up'"
	@kubectl -n local-infra get pods 2>/dev/null || true

local-doctor: ## Report what's up: kind cluster, Argo, CNPG operator, local-infra
	@echo "kube ctx   : $(KUBECONFIG)"
	@printf "cluster    : "; kubectl get ns argocd      >/dev/null 2>&1 && echo "up (argocd present)" || echo "DOWN — run 'sandboxctl up --with-cnpg ...'"
	@printf "cnpg op    : "; kubectl get ns cnpg-system >/dev/null 2>&1 && echo "present" || echo "MISSING — run 'sandboxctl up --with-cnpg'"
	@printf "local-infra: "; kubectl -n local-infra get cluster local-pg >/dev/null 2>&1 && echo "deployed" || echo "not deployed — run 'make local-up'"

local-down: ## Tear the whole sandbox down (wipes the kind cluster)
	sandboxctl down

local-help: ## List local targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
