{{/*
Expand the name of the chart.
*/}}
{{- define "keycloak.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "keycloak.fullname" -}}
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
{{- define "keycloak.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "keycloak.labels" -}}
helm.sh/chart: {{ include "keycloak.chart" . }}
{{ include "keycloak.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesseract-hub
app.kubernetes.io/component: identity
{{- end }}

{{/*
Selector labels
*/}}
{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keycloak.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "keycloak.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "keycloak.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get the admin password secret name
*/}}
{{- define "keycloak.adminSecretName" -}}
{{- if .Values.keycloak.admin.existingSecret }}
{{- .Values.keycloak.admin.existingSecret }}
{{- else }}
{{- include "keycloak.fullname" . }}-admin
{{- end }}
{{- end }}

{{/*
Get the database password secret name
*/}}
{{- define "keycloak.dbSecretName" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecret }}
{{- else }}
{{- include "keycloak.fullname" . }}-db
{{- end }}
{{- end }}

{{/*
Get the Keycloak hostname
*/}}
{{- define "keycloak.hostname" -}}
{{- if .Values.keycloak.hostname }}
{{- .Values.keycloak.hostname }}
{{- else if and .Values.ingress.enabled (gt (len .Values.ingress.hosts) 0) }}
{{- (index .Values.ingress.hosts 0).host }}
{{- else }}
{{- include "keycloak.fullname" . }}
{{- end }}
{{- end }}
