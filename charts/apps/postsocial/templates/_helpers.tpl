{{- define "postsocial.name" -}}
{{- default "postsocial" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "postsocial.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "postsocial" .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "postsocial.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "postsocial.labels" -}}
helm.sh/chart: {{ include "postsocial.chart" . }}
{{ include "postsocial.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: postsocial
{{- end }}

{{- define "postsocial.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postsocial.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "postsocial.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "postsocial.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
