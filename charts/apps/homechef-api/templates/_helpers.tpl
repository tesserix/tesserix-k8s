{{/*
Expand the name of the chart.
*/}}
{{- define "homechef-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "homechef-api.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "homechef-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "homechef-api.labels" -}}
helm.sh/chart: {{ include "homechef-api.chart" . }}
{{ include "homechef-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: home-chef-app
{{- end }}

{{/*
Selector labels
*/}}
{{- define "homechef-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "homechef-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "homechef-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "homechef-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Prod container env shared by the API Deployment and the Temporal worker
so they stay in lockstep. Use as:  env:\n{{- include "homechef-api.containerEnv" . | nindent 12 }}
(Note: deployment.yaml has its own local/kind-mode env and is intentionally not
refactored here; the worker is a prod-only concern.)
*/}}
{{- define "homechef-api.containerEnv" -}}
{{- range $key, $value := .Values.env }}
{{- if ne $key "PORT" }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
- name: DB_HOST
  value: {{ .Values.database.host | quote }}
- name: DB_PORT
  value: {{ .Values.database.port | quote }}
- name: DB_USER
  value: {{ .Values.database.user | quote }}
- name: DB_NAME
  value: {{ .Values.database.name | quote }}
- name: DB_SSLMODE
  value: {{ .Values.database.sslmode | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: DB_PASSWORD
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: REDIS_PASSWORD
- name: REDIS_URL
  value: "redis://:$(REDIS_PASSWORD)@{{ .Values.redis.host }}:{{ .Values.redis.port }}"
# MongoDB — in-app chat (#53), backed by the Percona-operator replica set. The
# operator generates the databaseAdmin credentials into <cluster>-secrets;
# optional so the API still starts before the operator has provisioned them
# (chat is then 503 until Mongo is reachable). Plaintext (no app-level TLS): the
# mongod listener is non-TLS and the wire is already encrypted by Istio ambient
# (ztunnel mTLS). The mongod pods opt out of the L7 waypoint so the wire protocol
# isn't mangled.
- name: MONGODB_USER
  valueFrom:
    secretKeyRef:
      name: homechef-mongodb-secrets
      key: MONGODB_DATABASE_ADMIN_USER
      optional: true
- name: MONGODB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: homechef-mongodb-secrets
      key: MONGODB_DATABASE_ADMIN_PASSWORD
      optional: true
- name: MONGODB_URI
  value: "mongodb://$(MONGODB_USER):$(MONGODB_PASSWORD)@homechef-mongodb-rs0.{{ .Release.Namespace }}.svc.cluster.local:27017/admin?replicaSet=rs0"
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: JWT_SECRET
- name: JWT_REFRESH_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: JWT_REFRESH_SECRET
- name: OTTO_INTERNAL_AUTH
  valueFrom:
    secretKeyRef:
      name: homechef-otto
      key: INTERNAL_AUTH_SECRET
      optional: true
- name: SUPPORT_HOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: homechef-otto
      key: SUPPORT_HOOK_SECRET
      optional: true
- name: OPENEXCHANGERATES_APP_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: OPENEXCHANGERATES_APP_ID
      optional: true
- name: EXCHANGERATES_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: EXCHANGERATES_API_KEY
      optional: true
{{- /*
Super-admin allowlist. Without this the API falls back to the list hardcoded in
apps/api/models/staff.go (three personal Gmail addresses), and
RequireStaffPermission auto-provisions a StaffMember with StaffRoleSuperAdmin
for any caller whose signed X-User-Email matches it. Sourcing it from Secret
Manager makes the list rotatable without a rebuild and keeps personal addresses
out of the compiled binary.

`optional: true` is deliberate: if the secret key is missing the app falls back
to its built-in default rather than starting with an EMPTY allowlist, which
would lock every super admin out of the console.
*/}}
- name: SUPER_ADMIN_EMAILS
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: SUPER_ADMIN_EMAILS
      optional: true
{{- /*
Sign in with Apple revocation (App Review 5.1.1(v)). The team id and the two
per-app client ids are plain env in values-prod.yaml; only these two come from
Secret Manager, and only once appleSignIn.revocationEnabled adds them to the
ExternalSecret.

`optional: true` for the same reason as above and because the API is built to
tolerate a partial config: config.warnIfAppleSignInIncomplete logs precisely
what is absent and revocation degrades to a no-op. Account deletion must never
fail because Apple credentials are misconfigured.
*/}}
- name: APPLE_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: APPLE_KEY_ID
      optional: true
- name: APPLE_SIGNIN_PRIVATE_KEY_B64
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: APPLE_SIGNIN_PRIVATE_KEY_B64
      optional: true
- name: SENDGRID_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: SENDGRID_API_KEY
      optional: true
- name: RESEND_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: RESEND_API_KEY
      optional: true
- name: BFF_INTERNAL_HMAC_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: BFF_INTERNAL_HMAC_KEY
# Optional: absent ⇒ POST /api/v1/feedback returns 503 rather than blocking startup.
- name: GITHUB_FEEDBACK_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: GITHUB_FEEDBACK_TOKEN
      optional: true
# Google Routes API key (#701) — optional: absent ⇒ haversine fallback, no startup block.
- name: GOOGLE_MAPS_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: GOOGLE_MAPS_API_KEY
      optional: true
# Google Weather API key (#706) — optional: absent ⇒ weather surge neutral.
- name: GOOGLE_WEATHER_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: GOOGLE_WEATHER_API_KEY
      optional: true
# Surge-pin HMAC key (#704-706) — optional: absent ⇒ surge stays display-only and
# is never charged, so a missing secret degrades safely instead of blocking startup.
- name: DELIVERY_SURGE_PIN_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: DELIVERY_SURGE_PIN_KEY
      optional: true
# Mappls (MapmyIndia) OAuth2 creds (#address-search) — primary geocoder.
# Optional: either absent ⇒ Photon (OSM) fallback, no startup block.
- name: MAPPLS_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: MAPPLS_CLIENT_ID
      optional: true
- name: MAPPLS_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "homechef-api.fullname" . }}-secrets
      key: MAPPLS_CLIENT_SECRET
      optional: true
{{- if .Values.email }}
- name: FROM_EMAIL
  value: {{ .Values.email.fromEmail | quote }}
- name: FROM_NAME
  value: {{ .Values.email.fromName | quote }}
{{- end }}
{{- if .Values.gcs }}
- name: GCS_PROJECT_ID
  value: {{ .Values.gcs.projectId | quote }}
- name: GCS_PUBLIC_BUCKET
  value: {{ .Values.gcs.publicBucket | quote }}
- name: GCS_PRIVATE_BUCKET
  value: {{ .Values.gcs.privateBucket | quote }}
{{- end }}
{{- end }}
