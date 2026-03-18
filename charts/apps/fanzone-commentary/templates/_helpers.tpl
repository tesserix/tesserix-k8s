{{/*
Expand the name of the chart.
*/}}
{{- define "fanzone-commentary.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fanzone-commentary.fullname" -}}
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
{{- define "fanzone-commentary.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fanzone-commentary.labels" -}}
helm.sh/chart: {{ include "fanzone-commentary.chart" . }}
{{ include "fanzone-commentary.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fanzone-battle-ground
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fanzone-commentary.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fanzone-commentary.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: commentary
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fanzone-commentary.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fanzone-commentary.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
