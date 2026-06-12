# Terraform Stack Orchestrator Makefile
# Manages multi-stack Terraform deployments with dependency awareness

.PHONY: help init plan apply destroy validate deps clean all

# Configuration
ENVIRONMENT ?= prod
STATE_BUCKET ?= tesseract-terraform-states
PROJECT_ID ?= tesseracthub-480811
REGION ?= us-central1

# Stacks in execution order
STACKS = 01-foundation 02-network 03-storage 04-gke 05-k8s-bootstrap \
         06-workload-identity 07-app-secrets 08-communication-services 09-github-arc \
         11-identity-platform 12-vertex

# Stacks in destroy order (reverse)
DESTROY_STACKS = 12-vertex 11-identity-platform 09-github-arc 08-communication-services 07-app-secrets \
                 06-workload-identity 05-k8s-bootstrap 04-gke 03-storage 02-network 01-foundation

# Default target
help:
	@echo ""
	@echo "Terraform Stack Orchestrator"
	@echo "============================"
	@echo ""
	@echo "Usage: make <target> [ENVIRONMENT=prod] [STACK=01-foundation]"
	@echo ""
	@echo "Targets:"
	@echo "  init         Initialize all stacks"
	@echo "  plan         Plan all stacks"
	@echo "  apply        Apply all stacks"
	@echo "  destroy      Destroy all stacks (reverse order)"
	@echo "  validate     Validate all stack configurations"
	@echo "  deps         Show dependency graph"
	@echo "  clean        Clean Terraform files"
	@echo ""
	@echo "Single Stack Operations:"
	@echo "  init-<stack>     Initialize specific stack"
	@echo "  plan-<stack>     Plan specific stack"
	@echo "  apply-<stack>    Apply specific stack"
	@echo "  destroy-<stack>  Destroy specific stack"
	@echo ""
	@echo "Stacks:"
	@echo "  01-foundation           GCP APIs"
	@echo "  02-network              VPC, Subnets, Firewall"
	@echo "  03-storage              Buckets, Secrets, KMS"
	@echo "  04-gke                  GKE Cluster"
	@echo "  05-k8s-bootstrap        Kong, Cert-Manager, ArgoCD"
	@echo "  06-workload-identity    Service Accounts, WI Bindings"
	@echo "  07-app-secrets          Application Secrets"
	@echo "  08-communication-services Email, SMS, Push"
	@echo "  09-github-arc           GitHub Actions Runners"
	@echo "  11-identity-platform    Google Identity Platform Tenants"
	@echo "  12-vertex               Vertex AI PSC, DNS pinning, gateway IAM"
	@echo ""
	@echo "Environment Variables:"
	@echo "  ENVIRONMENT   Target environment (default: prod)"
	@echo "  STATE_BUCKET  GCS bucket for state (default: tesseract-terraform-states)"
	@echo "  PROJECT_ID    GCP Project ID (default: tesseracthub-480811)"
	@echo ""

# Initialize all stacks (fail fast on error)
init:
	@for stack in $(STACKS); do \
		echo "==> Initializing $$stack"; \
		$(MAKE) init-$$stack || exit 1; \
	done

# Plan all stacks (fail fast on error)
plan:
	@for stack in $(STACKS); do \
		echo "==> Planning $$stack"; \
		$(MAKE) plan-$$stack || exit 1; \
	done

# Apply all stacks (fail fast on error)
apply:
	@for stack in $(STACKS); do \
		echo "==> Applying $$stack"; \
		$(MAKE) apply-$$stack || exit 1; \
	done

# Destroy all stacks (reverse order, fail fast on error)
destroy:
	@for stack in $(DESTROY_STACKS); do \
		echo "==> Destroying $$stack"; \
		$(MAKE) destroy-$$stack || exit 1; \
	done

# Validate all stacks (fail fast on error)
validate:
	@for stack in $(STACKS); do \
		echo "==> Validating $$stack"; \
		cd stacks/$$stack && terraform validate || exit 1; \
		cd ../..; \
	done

# Show dependency graph
deps:
	@./scripts/orchestrator.sh deps

# Clean Terraform files
clean:
	@find stacks -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
	@find stacks -name ".terraform.lock.hcl" -type f -delete 2>/dev/null || true
	@find stacks -name "*.tfplan" -type f -delete 2>/dev/null || true
	@echo "Cleaned Terraform files"

# =============================================================================
# Individual Stack Targets
# =============================================================================

# 01-foundation
init-01-foundation:
	@cd stacks/01-foundation && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/foundation" \
		-reconfigure

plan-01-foundation: init-01-foundation
	@cd stacks/01-foundation && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-out=01-foundation.tfplan

apply-01-foundation: init-01-foundation
	@cd stacks/01-foundation && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)"

destroy-01-foundation: init-01-foundation
	@cd stacks/01-foundation && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)"

# 02-network
init-02-network:
	@cd stacks/02-network && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/network" \
		-reconfigure

plan-02-network: init-02-network
	@cd stacks/02-network && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=02-network.tfplan

apply-02-network: init-02-network
	@cd stacks/02-network && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-02-network: init-02-network
	@cd stacks/02-network && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 03-storage
init-03-storage:
	@cd stacks/03-storage && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/storage" \
		-reconfigure

plan-03-storage: init-03-storage
	@cd stacks/03-storage && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=03-storage.tfplan

apply-03-storage: init-03-storage
	@cd stacks/03-storage && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-03-storage: init-03-storage
	@cd stacks/03-storage && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 04-gke
init-04-gke:
	@cd stacks/04-gke && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/gke" \
		-reconfigure

plan-04-gke: init-04-gke
	@cd stacks/04-gke && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=04-gke.tfplan

apply-04-gke: init-04-gke
	@cd stacks/04-gke && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-04-gke: init-04-gke
	@cd stacks/04-gke && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 05-k8s-bootstrap
init-05-k8s-bootstrap:
	@cd stacks/05-k8s-bootstrap && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/k8s-bootstrap" \
		-reconfigure

plan-05-k8s-bootstrap: init-05-k8s-bootstrap
	@cd stacks/05-k8s-bootstrap && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=05-k8s-bootstrap.tfplan

apply-05-k8s-bootstrap: init-05-k8s-bootstrap
	@cd stacks/05-k8s-bootstrap && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-05-k8s-bootstrap: init-05-k8s-bootstrap
	@cd stacks/05-k8s-bootstrap && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 06-workload-identity
init-06-workload-identity:
	@cd stacks/06-workload-identity && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/workload-identity" \
		-reconfigure

plan-06-workload-identity: init-06-workload-identity
	@cd stacks/06-workload-identity && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=06-workload-identity.tfplan

apply-06-workload-identity: init-06-workload-identity
	@cd stacks/06-workload-identity && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-06-workload-identity: init-06-workload-identity
	@cd stacks/06-workload-identity && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 07-app-secrets
init-07-app-secrets:
	@cd stacks/07-app-secrets && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/app-secrets" \
		-reconfigure

plan-07-app-secrets: init-07-app-secrets
	@cd stacks/07-app-secrets && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=07-app-secrets.tfplan

apply-07-app-secrets: init-07-app-secrets
	@cd stacks/07-app-secrets && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-07-app-secrets: init-07-app-secrets
	@cd stacks/07-app-secrets && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 08-communication-services
init-08-communication-services:
	@cd stacks/08-communication-services && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/communication-services" \
		-reconfigure

plan-08-communication-services: init-08-communication-services
	@cd stacks/08-communication-services && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=08-communication-services.tfplan

apply-08-communication-services: init-08-communication-services
	@cd stacks/08-communication-services && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-08-communication-services: init-08-communication-services
	@cd stacks/08-communication-services && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 09-github-arc
init-09-github-arc:
	@cd stacks/09-github-arc && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/github-arc" \
		-reconfigure

plan-09-github-arc: init-09-github-arc
	@cd stacks/09-github-arc && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=09-github-arc.tfplan

apply-09-github-arc: init-09-github-arc
	@cd stacks/09-github-arc && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-09-github-arc: init-09-github-arc
	@cd stacks/09-github-arc && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 11-identity-platform
init-11-identity-platform:
	@cd stacks/11-identity-platform && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/identity-platform" \
		-reconfigure

plan-11-identity-platform: init-11-identity-platform
	@cd stacks/11-identity-platform && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=11-identity-platform.tfplan

apply-11-identity-platform: init-11-identity-platform
	@cd stacks/11-identity-platform && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-11-identity-platform: init-11-identity-platform
	@cd stacks/11-identity-platform && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# 12-vertex
init-12-vertex:
	@cd stacks/12-vertex && \
	terraform init \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="prefix=stacks/$(ENVIRONMENT)/vertex" \
		-reconfigure

plan-12-vertex: init-12-vertex
	@cd stacks/12-vertex && \
	terraform plan \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)" \
		-out=12-vertex.tfplan

apply-12-vertex: init-12-vertex
	@cd stacks/12-vertex && \
	terraform apply -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

destroy-12-vertex: init-12-vertex
	@cd stacks/12-vertex && \
	terraform destroy -auto-approve \
		-var-file="../../environments/$(ENVIRONMENT)/terraform.tfvars" \
		-var="project_id=$(PROJECT_ID)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="state_bucket=$(STATE_BUCKET)"

# =============================================================================
# Bootstrap Target (Create State Bucket)
# =============================================================================

bootstrap:
	@echo "Creating Terraform state bucket..."
	@gsutil mb -p $(PROJECT_ID) -l $(REGION) gs://$(STATE_BUCKET) 2>/dev/null || true
	@gsutil versioning set on gs://$(STATE_BUCKET)
	@echo "State bucket ready: gs://$(STATE_BUCKET)"

# =============================================================================
# All (Full Deployment)
# =============================================================================

all: bootstrap init apply
	@echo "Full deployment complete!"
