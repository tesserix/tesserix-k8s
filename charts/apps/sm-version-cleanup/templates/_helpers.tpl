{{/*
Chart name
*/}}
{{- define "sm-version-cleanup.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname
*/}}
{{- define "sm-version-cleanup.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "sm-version-cleanup.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "sm-version-cleanup.labels" -}}
helm.sh/chart: {{ include "sm-version-cleanup.name" . }}
app.kubernetes.io/name: {{ include "sm-version-cleanup.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: platform-cleanup
app.kubernetes.io/part-of: platform
{{- end }}

{{/*
Selector labels
*/}}
{{- define "sm-version-cleanup.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sm-version-cleanup.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "sm-version-cleanup.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sm-version-cleanup.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
