{{/*
GCP Secret Manager Integration Helpers
These templates provide standard patterns for GCP Secret Manager integration
using Workload Identity for authentication.
*/}}

{{/*
Generate Workload Identity annotation for service accounts.
This links the Kubernetes service account to a GCP service account.
Usage: {{ include "common.workloadIdentityAnnotation" . }}
*/}}
{{- define "common.workloadIdentityAnnotation" -}}
{{- if and .Values.gcp .Values.gcp.workloadIdentity .Values.gcp.workloadIdentity.enabled }}
iam.gke.io/gcp-service-account: {{ .Values.gcp.workloadIdentity.gcpServiceAccount }}
{{- end }}
{{- end -}}

{{/*
Generate full GCP service account email.
Usage: {{ include "common.gcpServiceAccountEmail" . }}
*/}}
{{- define "common.gcpServiceAccountEmail" -}}
{{- if and .Values.gcp .Values.gcp.workloadIdentity }}
app-secrets-{{ .Values.gcp.namespace | default .Release.Namespace }}@{{ .Values.gcp.projectId }}.iam.gserviceaccount.com
{{- end }}
{{- end -}}

{{/*
Generate GCP Secret Manager environment variables.
These are added to deployments to enable GCP Secret Manager SDK usage.
GCP_PROJECT_ID is optional - SDK auto-detects from GKE metadata server.
Usage: {{ include "common.gcpSecretEnvVars" . | nindent 12 }}
*/}}
{{- define "common.gcpSecretEnvVars" -}}
{{- if and .Values.gcp .Values.gcp.secretManager .Values.gcp.secretManager.enabled }}
{{- /* GCP_PROJECT_ID is optional - SDK auto-fetches from metadata server on GKE */}}
{{- if .Values.gcp.projectId }}
- name: GCP_PROJECT_ID
  value: {{ .Values.gcp.projectId | quote }}
{{- end }}
- name: GCP_SECRET_PREFIX
  value: {{ .Values.gcp.secretManager.secretPrefix | default "dev" | quote }}
- name: USE_GCP_SECRET_MANAGER
  value: "true"
{{- end }}
{{- end -}}

{{/*
Generate environment variable from GCP Secret Manager secret.
Usage: {{ include "common.secretEnvVar" (dict "name" "DB_PASSWORD" "secretName" "postgresql-password" "context" .) }}
*/}}
{{- define "common.secretEnvVar" -}}
{{- if and .context.Values.gcp .context.Values.gcp.secretManager .context.Values.gcp.secretManager.enabled }}
- name: {{ .name }}_SECRET_NAME
  value: {{ printf "%s-%s" (.context.Values.gcp.secretManager.secretPrefix | default "dev") .secretName | quote }}
{{- end }}
{{- end -}}

{{/*
Generate database password from GCP Secret Manager.
Usage: {{ include "common.databasePasswordEnv" . | nindent 12 }}
*/}}
{{- define "common.databasePasswordEnv" -}}
{{- if and .Values.gcp .Values.gcp.secretManager .Values.gcp.secretManager.enabled }}
{{- if .Values.postgresql.enabled }}
- name: DB_PASSWORD_SECRET_NAME
  value: {{ printf "%s-%s-postgresql-password" (.Values.gcp.secretManager.secretPrefix | default "dev") (.Values.gcp.namespace | default .Release.Namespace) | quote }}
{{- end }}
{{- else if .Values.postgresql.enabled }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgresql.existingSecret }}
      key: {{ .Values.postgresql.existingSecretKey }}
{{- end }}
{{- end -}}

{{/*
Generate Redis password from GCP Secret Manager.
Usage: {{ include "common.redisPasswordEnv" . | nindent 12 }}
*/}}
{{- define "common.redisPasswordEnv" -}}
{{- if and .Values.gcp .Values.gcp.secretManager .Values.gcp.secretManager.enabled }}
{{- if .Values.redis.enabled }}
- name: REDIS_PASSWORD_SECRET_NAME
  value: {{ printf "%s-%s-redis-password" (.Values.gcp.secretManager.secretPrefix | default "dev") (.Values.gcp.namespace | default .Release.Namespace) | quote }}
{{- end }}
{{- else if and .Values.redis .Values.redis.enabled }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redis.existingSecret }}
      key: {{ .Values.redis.existingSecretKey }}
{{- end }}
{{- end -}}

{{/*
Generate JWT secret from GCP Secret Manager.
Usage: {{ include "common.jwtSecretEnv" . | nindent 12 }}
*/}}
{{- define "common.jwtSecretEnv" -}}
{{- if and .Values.gcp .Values.gcp.secretManager .Values.gcp.secretManager.enabled }}
{{- if .Values.jwt.enabled }}
- name: JWT_SECRET_NAME
  value: {{ printf "%s-jwt-secret" (.Values.gcp.secretManager.secretPrefix | default "dev") | quote }}
{{- end }}
{{- else if and .Values.jwt .Values.jwt.enabled }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.jwt.existingSecret }}
      key: {{ .Values.jwt.existingSecretKey }}
{{- end }}
{{- end -}}

{{/*
Generate full service account template with Workload Identity.
Usage: {{ include "common.serviceAccount" (dict "name" "my-service" "context" .) }}
*/}}
{{- define "common.serviceAccount" -}}
{{- if .context.Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}
  labels:
    {{- include (printf "%s.labels" .chartName) .context | nindent 4 }}
  annotations:
    {{- if and .context.Values.gcp .context.Values.gcp.workloadIdentity .context.Values.gcp.workloadIdentity.enabled }}
    iam.gke.io/gcp-service-account: {{ .context.Values.gcp.workloadIdentity.gcpServiceAccount }}
    {{- end }}
    {{- with .context.Values.serviceAccount.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
automountServiceAccountToken: {{ .context.Values.serviceAccount.automount }}
{{- end }}
{{- end -}}

{{/*
Standard GCP configuration values for values.yaml.
Copy this block to your chart's values.yaml:

gcp:
  projectId: ""
  namespace: ""  # Override if different from release namespace
  workloadIdentity:
    enabled: false
    gcpServiceAccount: ""  # e.g., app-secrets-global@project.iam.gserviceaccount.com
  secretManager:
    enabled: false
    secretPrefix: "dev"  # Environment prefix: dev, staging, prod
*/}}
