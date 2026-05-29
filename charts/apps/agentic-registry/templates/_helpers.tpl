{{- define "agentic-registry.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "agentic-registry.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "agentic-registry.labels" -}}
app.kubernetes.io/name: {{ include "agentic-registry.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "agentic-registry.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agentic-registry.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "agentic-registry.serviceAccountName" -}}
{{- default (include "agentic-registry.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "agentic-registry.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
