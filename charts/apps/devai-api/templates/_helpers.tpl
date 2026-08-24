{{- define "devai-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "devai-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "devai-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "devai-api.labels" -}}
helm.sh/chart: {{ include "devai-api.chart" . }}
{{ include "devai-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devai
{{- end }}

{{- define "devai-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devai-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "devai-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "devai-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Shared container env for the API server and the Temporal worker.
Both run the same image and the same blueprint stages, so they need an
identical environment — defined once here so the two never drift.
*/}}
{{- define "devai-api.containerEnv" -}}
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
# ─── Auth gate ────────────────────────────────────────
# DEVAI_REQUIRE_AUTH flips the in-app enforce_auth check from advisory to
# blocking: when true, anonymous mutating calls are rejected (401) instead
# of falling through with a synthetic principal. Default false preserves
# the current (pre-flip) behavior — the deliberate prod flip lives in
# values-prod.yaml and is sequenced AFTER the new images ship.
- name: DEVAI_REQUIRE_AUTH
  value: {{ .Values.requireAuth | default false | quote }}
# Shared secret the auth-bff stamps as X-Auth-Bff-Secret so the
# X-Forwarded-* trust path can be validated (identity._forward_trusted).
# Sourced from the same secret the auth-bff is provisioned from. Marked
# optional so the pod still starts before the key is added to the
# devai-auth-bff-secrets ExternalSecret (auth-bff lane owns that file);
# until both sides carry it, the gate fails closed on forwarded identity.
- name: DEVAI_AUTH_BFF_SHARED_SECRET
  valueFrom:
    secretKeyRef:
      name: devai-auth-bff-secrets
      key: DEVAI_AUTH_BFF_SHARED_SECRET
      optional: true
# The secret above is optional, so an ExternalSecret failure silently empties
# it — and an empty shared secret means "trust X-Forwarded-* from anyone".
# false makes that case fail closed instead (identity._forward_trusted).
# Only rendered when set: a `default true` would rewrite an explicit false.
{{- if hasKey .Values "trustForwardedWithoutSecret" }}
- name: DEVAI_TRUST_FORWARDED_WITHOUT_SECRET
  value: {{ .Values.trustForwardedWithoutSecret | quote }}
{{- end }}
# Confines the document-ingestion tools (doc_read_pdf / doc_read_markdown /
# doc_parse_openapi) to one directory. Their file_path is regex-extracted from
# issue text, so an unconfined pod reads whatever an issue author names.
{{- with .Values.toolWorkspaceRoot }}
- name: DEVAI_TOOL_WORKSPACE_ROOT
  value: {{ . | quote }}
{{- end }}
# MCP Hub ↔ devai-api shared service bearer: the Hub presents it toward the
# per-domain MCP servers (authMode=jwt) and devai-api verifies it
# (identity._principal_from_service_bearer). Same key the devai-mcp-hub
# chart reads from devai-api-secrets. Optional so the pod starts before the
# ExternalSecret key lands — until then Hub federation of jwt domains 401s.
- name: DEVAI_MCP_HUB_SERVICE_TOKEN
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_MCP_HUB_SERVICE_TOKEN
      optional: true
# Database — password must be defined before URL for $(VAR) expansion
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgresql-devai-password
      key: password
- name: DEVAI_DATABASE_URL
  # ?sslmode=disable so asyncpg / sqlalchemy don't attempt
  # SSL startTLS against the CNPG pooler (which resets the
  # connection mid-upgrade). Intra-cluster encryption is
  # handled by Istio.
  value: "postgresql://{{ .Values.database.user }}:$(DB_PASSWORD)@{{ .Values.database.host }}:{{ .Values.database.port }}/{{ .Values.database.name }}?sslmode=disable"
# redis.user is the Valkey ACL user that confines this app to its own key
# prefix. The user is nopass and the literal below is discarded, but clients
# skip AUTH entirely when the password is empty — hence a placeholder.
- name: DEVAI_REDIS_URL
  value: "redis://{{ with .Values.redis.user }}{{ . }}:nopass@{{ end }}{{ .Values.redis.host }}:{{ .Values.redis.port }}"
# NATS
- name: DEVAI_NATS_URL
  value: {{ .Values.nats.url | quote }}
# ─── Fiber-style blueprint runtime + adapters ─────────
{{- if .Values.pipeline }}
- name: DEVAI_PIPELINE_ENABLED
  value: {{ .Values.pipeline.enabled | default false | quote }}
- name: DEVAI_PIPELINE_BLUEPRINT_DIR
  value: {{ .Values.pipeline.blueprintDir | default "blueprints" | quote }}
- name: DEVAI_PIPELINE_DEFAULT_BLUEPRINT
  value: {{ .Values.pipeline.defaultBlueprint | default "alm-pipeline" | quote }}
- name: DEVAI_PIPELINE_PR_REVIEW_BLUEPRINT
  value: {{ .Values.pipeline.prReviewBlueprint | default "pr-review" | quote }}
- name: DEVAI_PIPELINE_SRE_BLUEPRINT
  value: {{ .Values.pipeline.sreBlueprint | default "sre-monitor" | quote }}
- name: DEVAI_PIPELINE_CONCURRENCY
  value: {{ .Values.pipeline.concurrency | default 4 | quote }}
- name: DEVAI_PIPELINE_DEFAULT_STAGE_TIMEOUT
  value: {{ .Values.pipeline.defaultStageTimeout | default 900 | quote }}
{{- end }}
{{- if .Values.specializations }}
- name: DEVAI_SPECIALIZATIONS_ENABLED
  value: {{ .Values.specializations.enabled | default true | quote }}
- name: DEVAI_SPECIALIZATIONS_DIR
  value: {{ .Values.specializations.dir | default "specializations" | quote }}
{{- end }}
{{- if .Values.memory }}
- name: DEVAI_MEMORY_PROVIDER
  value: {{ .Values.memory.provider | default "noop" | quote }}
# Embedding provider for memory semantic search (pgvector). "auto" uses
# OpenAI when DEVAI_OPENAI_API_KEY is present (wired below from the
# ExternalSecret); without it pgvector degrades to keyword recall.
# Dimensions must match the agent_memories.embedding column: vector(1536).
- name: DEVAI_EMBEDDING_PROVIDER
  value: {{ .Values.memory.embeddingProvider | default "auto" | quote }}
- name: DEVAI_EMBEDDING_MODEL
  value: {{ .Values.memory.embeddingModel | default "text-embedding-3-small" | quote }}
- name: DEVAI_EMBEDDING_DIMENSIONS
  value: {{ .Values.memory.embeddingDimensions | default 1536 | quote }}
# Qdrant — only read when provider is "qdrant". The collection is created
# on first write at DEVAI_EMBEDDING_DIMENSIONS, so changing the embedding
# model means a new collection name, not a resized one.
- name: DEVAI_QDRANT_URL
  value: {{ .Values.memory.qdrantUrl | default "" | quote }}
- name: DEVAI_QDRANT_COLLECTION
  value: {{ .Values.memory.qdrantCollection | default "devai_memories" | quote }}
- name: DEVAI_QDRANT_API_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_QDRANT_API_KEY
      optional: true
{{- end }}
{{- if .Values.objectStore }}
- name: DEVAI_OBJECT_STORE_PROVIDER
  value: {{ .Values.objectStore.provider | default "noop" | quote }}
- name: DEVAI_OBJECT_STORE_BUCKET
  value: {{ .Values.objectStore.bucket | default "" | quote }}
- name: DEVAI_OBJECT_STORE_PREFIX
  value: {{ .Values.objectStore.prefix | default "devai" | quote }}
{{- end }}
# ─── Settings capability (per-user/per-tenant connectors + secrets) ──
# Connectors are persisted in the user_settings table; secret VALUES are
# auto-provisioned into GCP Secret Manager via the secrets adapter (the
# devai SA needs Secret Manager write IAM for gcp_sm to provision — until
# then non-secret prefs work and secret writes return 409). See
# devai/docs/SETTINGS_CAPABILITY.md.
{{- if .Values.settings }}
- name: DEVAI_SETTINGS_ENABLED
  value: {{ .Values.settings.enabled | default true | quote }}
- name: DEVAI_SECRETS_PROVIDER
  value: {{ .Values.settings.secretsProvider | default "noop" | quote }}
- name: DEVAI_SECRETS_GCP_PROJECT
  value: {{ .Values.settings.secretsGcpProject | default .Values.gcp.projectId | default "" | quote }}
- name: DEVAI_SECRETS_OPENBAO_ADDR
  value: {{ .Values.settings.openbaoAddress | default "" | quote }}
- name: DEVAI_SECRETS_OPENBAO_MOUNT
  value: {{ .Values.settings.openbaoMount | default "kv" | quote }}
- name: DEVAI_SECRETS_OPENBAO_ROLE
  value: {{ .Values.settings.openbaoRole | default "read-devai-api" | quote }}
- name: DEVAI_SECRETS_OPENBAO_AUTH_MOUNT
  value: {{ .Values.settings.openbaoAuthMount | default "kubernetes" | quote }}
- name: DEVAI_SECRETS_BROKER_URL
  value: {{ .Values.settings.brokerUrl | default "" | quote }}
- name: DEVAI_SECRETS_BROKER_TOKEN_FILE
  value: {{ .Values.settings.brokerTokenFile | default "/var/run/secrets/devai/secret-service/token" | quote }}
{{- end }}
# ─── K8s Job runtime (SDD blueprint runner) ──────────
{{- if .Values.k8sRuntime }}
- name: DEVAI_K8S_RUNTIME_ENABLED
  value: {{ .Values.k8sRuntime.enabled | default false | quote }}
- name: DEVAI_K8S_RUNTIME_NAMESPACE
  value: {{ .Values.k8sRuntime.namespace | default "devai" | quote }}
- name: DEVAI_K8S_RUNNER_SERVICE_ACCOUNT
  value: {{ .Values.k8sRuntime.runnerServiceAccount | default "devai-runner" | quote }}
- name: DEVAI_K8S_PULL_SECRET_NAME
  value: {{ .Values.k8sRuntime.pullSecretName | default "" | quote }}
- name: DEVAI_K8S_JOB_TTL_SECONDS
  value: {{ .Values.k8sRuntime.jobTtlSeconds | default 3600 | quote }}
- name: DEVAI_K8S_JOB_BACKOFF_LIMIT
  value: {{ .Values.k8sRuntime.jobBackoffLimit | default 0 | quote }}
- name: DEVAI_RUNNER_IMAGE
  value: {{ .Values.k8sRuntime.runnerImage | default "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/devai/devai-runner:main" | quote }}
- name: DEVAI_RUNNER_IMAGE_PER_STACK
  # pydantic-settings parses dict fields from a JSON-encoded
  # string when supplied via env. Keep this as a single line.
  value: {{ .Values.k8sRuntime.runnerImagePerStack | default "{}" | quote }}
- name: DEVAI_PREVIEW_DOMAIN
  value: {{ .Values.k8sRuntime.previewDomain | default "tesserix.app" | quote }}
- name: DEVAI_PREVIEW_NAMESPACE
  value: {{ .Values.k8sRuntime.previewNamespace | default "devai-previews" | quote }}
- name: DEVAI_EDITOR_BRIDGE_IMAGE
  value: {{ .Values.k8sRuntime.editorBridgeImage | default "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/devai/devai-editor-bridge:main" | quote }}
{{- end }}
# Agentic control planes (aregistry / agentgateway / kagent)
{{- if .Values.agenticControlPlane }}
- name: DEVAI_AREGISTRY_URL
  value: {{ .Values.agenticControlPlane.aregistryUrl | default "" | quote }}
# DEVAI_REGISTRY_URL is what the new src/devai/registry/
# client reads — alias to the same URL. (Older code paths
# still read DEVAI_AREGISTRY_URL; the two stay in sync.)
- name: DEVAI_REGISTRY_URL
  value: {{ .Values.agenticControlPlane.aregistryUrl | default "" | quote }}
{{- with .Values.agenticControlPlane.registryDeployKeySecret }}
# Platform-owned tenant writer key. Agentic Registry stores only its SHA-256
# digest and limits this credential to registry:read/write in the devai tenant.
- name: DEVAI_REGISTRY_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .name | quote }}
      key: {{ .key | quote }}
{{- end }}
# Publish-on-author — when an operator composes an agent / skill / tool /
# blueprint in the dashboard, devai-api publishes it to the shared
# registry (writes are mesh-gated to the devai-api SA; see the agentic
# AuthorizationPolicy). registryPublishOnBoot reconciles the catalog after
# a registry wipe or a devai redeploy.
- name: DEVAI_REGISTRY_PUBLISH_ENABLED
  value: {{ .Values.agenticControlPlane.registryPublishEnabled | default false | quote }}
- name: DEVAI_REGISTRY_DEFAULT_TENANT
  value: {{ .Values.agenticControlPlane.registryDefaultTenant | default "devai" | quote }}
- name: DEVAI_REGISTRY_PUBLISH_ON_BOOT
  value: {{ .Values.agenticControlPlane.registryPublishOnBoot | default false | quote }}
# Auth-bff session key — the dashboard proxies /api straight to devai-api
# (bypassing the bff), so devai-api decrypts the bff's AES-GCM devai_session
# cookie itself to authenticate the caller. Same key the bff mints with.
- name: DEVAI_BFF_SESSION_ENCRYPT_KEY
  valueFrom:
    secretKeyRef:
      name: devai-auth-bff-secrets
      key: DEVAI_BFF_SESSION_ENCRYPT_KEY
- name: DEVAI_AGENTGATEWAY_URL
  value: {{ .Values.agenticControlPlane.agentgatewayUrl | default "" | quote }}
# Master switch for kagent A2A dispatch (the platform default). A
# user/team/org/tenant can override it dynamically via the Settings
# "kagent" connector (on/off) — that takes effect on the next run
# with no restart. Off here = every agent runs as a Job.
- name: DEVAI_KAGENT_ENABLED
  value: {{ .Values.agenticControlPlane.kagentEnabled | default false | quote }}
# kagent control-plane URL. The dispatcher routes an agent over
# A2A through kagent's lifecycle controller ONLY when that agent's
# registry record carries `devai.io/runtime=kagent`; every other
# agent still dispatches as a K8s Job. Empty here disables kagent
# routing entirely (Jobs only). See docs/agentic/AGENTIC-INTEGRATION.md.
- name: DEVAI_KAGENT_URL
  value: {{ .Values.agenticControlPlane.kagentUrl | default "" | quote }}
# Per-user kagent keys. When true, the dispatcher forwards the triggering
# user's OWN LLM key as the A2A Bearer token, so a shared kagent agent
# (apiKeyPassthrough ModelConfig) runs on each user's own key; a user with no
# own key for kagentModelProvider falls back to a Job. Must match the kagent
# ModelConfig's provider (kagent-agent-sync values.modelConfig.provider).
- name: DEVAI_KAGENT_PASSTHROUGH
  value: {{ .Values.agenticControlPlane.kagentPassthrough | default false | quote }}
- name: DEVAI_KAGENT_MODEL_PROVIDER
  value: {{ .Values.agenticControlPlane.kagentModelProvider | default "anthropic" | quote }}
{{- if .Values.agenticControlPlane.kagentCatalog }}
# JSON catalog of kagent (provider, model)→suffix variants — MUST mirror the
# kagent-agent-sync chart's kagentModels (providers lowercased). DevAI maps the
# user's chosen (provider, model) to the variant `<agent>-<suffix>`.
- name: DEVAI_KAGENT_CATALOG
  value: {{ .Values.agenticControlPlane.kagentCatalog | toJson | quote }}
{{- end }}
{{- end }}
# GCP project
- name: GCP_PROJECT
  value: {{ .Values.gcp.projectId | default "" | quote }}
# Secrets from ExternalSecret
- name: DEVAI_OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_OPENAI_API_KEY
- name: DEVAI_ANTHROPIC_API_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_ANTHROPIC_API_KEY
# LLM gateway routing — Anthropic adapter dials this base
# URL instead of api.anthropic.com directly. The gateway
# (devai-ai-gateway in agentgateway-system NS) injects the
# x-api-key header itself, so future rotations don't need
# a devai-api restart. Empty value falls back to the SDK's
# default (direct to public Anthropic API).
- name: DEVAI_ANTHROPIC_BASE_URL
  value: {{ .Values.llm.anthropicBaseUrl | default "" | quote }}
- name: DEVAI_OPENAI_BASE_URL
  value: {{ .Values.llm.openaiBaseUrl | default "" | quote }}
- name: DEVAI_LLM_GATEWAY_BASE_URL
  value: {{ .Values.llm.gatewayBaseUrl | default "" | quote }}
- name: DEVAI_LLM_GATEWAY_REQUIRED
  value: {{ .Values.llm.gatewayRequired | default false | quote }}
{{- if .Values.llm.vertexEnabled }}
# Vertex AI — keyless (Workload Identity ADC) + VPC-private (PSC-pinned
# aiplatform DNS zone, terraform-new/stacks/12-vertex). Selectable as
# llm_provider=vertex_gemini globally or per specialization.
- name: DEVAI_VERTEX_PROJECT
  value: {{ .Values.llm.vertexProject | default .Values.gcp.projectId | quote }}
- name: DEVAI_VERTEX_LOCATION
  value: {{ .Values.llm.vertexLocation | default "global" | quote }}
- name: DEVAI_VERTEX_GEMINI_MODEL
  value: {{ .Values.llm.vertexGeminiModel | default "gemini-2.5-flash" | quote }}
{{- if .Values.llm.vertexBaseUrl }}
- name: DEVAI_VERTEX_BASE_URL
  value: {{ .Values.llm.vertexBaseUrl | quote }}
{{- end }}
{{- end }}
{{- if .Values.llm.systemPrincipal }}
# Service principal: SRE/webhook/cron runs resolve THIS user's Settings
# LLM connector (same overlay + gateway path), so automation also uses a
# tenant connector instead of the raw shared keys. Falls back to the
# platform chain only when this user has no connector.
- name: DEVAI_LLM_SYSTEM_PRINCIPAL
  value: {{ .Values.llm.systemPrincipal | quote }}
{{- end }}
{{- if .Values.llm.trialTokenBudget }}
# Free-trial allowance for users without their own connector: metered on
# the platform chain, permanently revoked at exhaustion (Redis counter).
- name: DEVAI_LLM_TRIAL_TOKEN_BUDGET
  value: {{ .Values.llm.trialTokenBudget | quote }}
{{- end }}
{{- if .Values.llm.requireUserConnector }}
# Strict tenant isolation: human principals MUST bring their own LLM
# connector (Settings) — the shared platform keys are never used for
# them. Webhook/system principals keep the platform chain so automation
# never breaks.
- name: DEVAI_LLM_REQUIRE_USER_CONNECTOR
  value: "true"
{{- end }}
{{- if .Values.llm.provider }}
# The platform-default LLM backend (per-user/per-spec choices override it).
- name: DEVAI_LLM_PROVIDER
  value: {{ .Values.llm.provider | quote }}
{{- end }}
{{- if .Values.llm.fallbackProvider }}
# Runtime resilience: calls that fail on the primary provider retry on
# this backend (its own default model) — outages degrade, never fail runs.
- name: DEVAI_LLM_FALLBACK_PROVIDER
  value: {{ .Values.llm.fallbackProvider | quote }}
{{- end }}
{{- if .Values.llm.tierLight }}
# Cost tiers — resolve_llm_tier() maps these "provider:model" pairs so
# stages/specs can ask for light|standard|heavy|frontier instead of
# hardcoding a provider.
- name: DEVAI_LLM_TIER_LIGHT
  value: {{ .Values.llm.tierLight | quote }}
- name: DEVAI_LLM_TIER_STANDARD
  value: {{ .Values.llm.tierStandard | default .Values.llm.tierLight | quote }}
- name: DEVAI_LLM_TIER_HEAVY
  value: {{ .Values.llm.tierHeavy | default "" | quote }}
- name: DEVAI_LLM_TIER_FRONTIER
  value: {{ .Values.llm.tierFrontier | default "" | quote }}
{{- end }}
- name: DEVAI_GROQ_API_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GROQ_API_KEY
- name: DEVAI_GITHUB_APP_ID
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GITHUB_APP_ID
- name: DEVAI_GITHUB_APP_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GITHUB_APP_PRIVATE_KEY
- name: DEVAI_GITHUB_APP_INSTALLATION_ID
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GITHUB_APP_INSTALLATION_ID
- name: DEVAI_GITHUB_WEBHOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GITHUB_WEBHOOK_SECRET
- name: DEVAI_GITHUB_OAUTH_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GITHUB_OAUTH_CLIENT_ID
- name: DEVAI_GITHUB_OAUTH_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GITHUB_OAUTH_CLIENT_SECRET
# PAT for SCM operations (list repos, create repos, list
# issues for the Workflows kanban). Source: the
# devai-github-pat Secret synced from GCP SM key
# prod-devai-github-pat via the ExternalSecret in
# external-secrets/prod/devai/. Setting DEVAI_SCM_TOKEN +
# DEVAI_SCM_AUTH_METHOD=pat makes the SCM factory use the
# PAT branch instead of GitHub App tokens; the rest of the
# client surface (list_installation_repos / create_repo /
# list_issues) works the same.
# PAT kept as a fallback credential, but auth method is now the GitHub App
# (App ID + private key + installation 138842580, synced via devai-api-secrets
# from GCP SM prod-devai-github-app-*). The App isn't subject to the org's
# classic-PAT block, so org-level GraphQL (Projects v2) works once the App has
# the Organization → Projects: R/W permission granted.
- name: DEVAI_SCM_TOKEN
  valueFrom:
    secretKeyRef:
      name: devai-github-pat
      key: token
- name: DEVAI_SCM_AUTH_METHOD
  value: "github_app"
- name: DEVAI_LANGCHAIN_API_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_LANGCHAIN_API_KEY
# NOTE: DEVAI_OPENAI_API_KEY is already declared above (next to
# DEVAI_ANTHROPIC_API_KEY). A second entry here was a duplicate —
# harmless under client-side apply but rejected by ArgoCD's
# ServerSideApply ("duplicate entries for key"). Removed.
- name: DEVAI_GEMINI_API_KEY
  valueFrom:
    secretKeyRef:
      name: devai-api-secrets
      key: DEVAI_GEMINI_API_KEY
{{- if .Values.temporal }}
# ─── Durable orchestration (Temporal) ────────────────────
# Shared by devai-api (enqueues blueprint runs) and devai-worker
# (executes them). provider=temporal routes every blueprint through
# the one generic BlueprintWorkflow; absent/inproc keeps in-process
# execution. Same config on both so they can never drift.
- name: DEVAI_WORKFLOW_PROVIDER
  value: {{ .Values.temporal.provider | default "temporal" | quote }}
- name: DEVAI_TEMPORAL_HOST
  value: {{ .Values.temporal.host | default "temporal.scrapper.svc.cluster.local:7233" | quote }}
- name: DEVAI_TEMPORAL_NAMESPACE
  value: {{ .Values.temporal.namespace | default "default" | quote }}
- name: DEVAI_TEMPORAL_TASK_QUEUE
  value: {{ .Values.temporal.taskQueue | default "devai" | quote }}
- name: DEVAI_TEMPORAL_TLS_ENABLED
  value: {{ .Values.temporal.tlsEnabled | default false | quote }}
- name: DEVAI_TEMPORAL_FAIL_CLOSED
  value: {{ .Values.temporal.failClosed | default false | quote }}
- name: DEVAI_TEMPORAL_PAYLOAD_ENCRYPTION_REQUIRED
  value: {{ .Values.temporal.payloadEncryptionRequired | default false | quote }}
{{- with .Values.temporal.payloadEncryptionSecret }}
- name: DEVAI_TEMPORAL_PAYLOAD_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .name | quote }}
      key: {{ .key | quote }}
{{- end }}
- name: DEVAI_TEMPORAL_MAX_CONCURRENT_ACTIVITIES
  value: {{ .Values.temporal.maxConcurrentActivities | default 50 | quote }}
- name: DEVAI_TEMPORAL_MAX_STAGE_ATTEMPTS
  value: {{ .Values.temporal.maxStageAttempts | default 3 | quote }}
- name: DEVAI_TEMPORAL_WORKER_DEPENDENCIES_REQUIRED
  value: {{ .Values.temporal.workerDependenciesRequired | default false | quote }}
- name: DEVAI_TEMPORAL_WORKER_VERSIONING_ENABLED
  value: {{ .Values.temporal.workerVersioningEnabled | default false | quote }}
- name: DEVAI_TEMPORAL_WORKER_DEPLOYMENT_NAME
  value: {{ .Values.temporal.workerDeploymentName | default "devai" | quote }}
- name: DEVAI_TEMPORAL_WORKER_BUILD_ID
  value: {{ .Values.temporal.workerBuildId | default .Values.image.tag | quote }}
- name: DEVAI_TEMPORAL_WORKER_GRACEFUL_SHUTDOWN_SECONDS
  value: {{ .Values.temporal.workerGracefulShutdownSeconds | default 60 | quote }}
{{- end }}
{{- end }}
