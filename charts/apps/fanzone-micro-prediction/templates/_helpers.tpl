{{/*
Expand the name of the chart.
*/}}
{{- define "fanzone-micro-prediction.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fanzone-micro-prediction.fullname" -}}
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
{{- define "fanzone-micro-prediction.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fanzone-micro-prediction.labels" -}}
helm.sh/chart: {{ include "fanzone-micro-prediction.chart" . }}
{{ include "fanzone-micro-prediction.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fanzone-battle-ground
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fanzone-micro-prediction.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fanzone-micro-prediction.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: micro-prediction
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fanzone-micro-prediction.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fanzone-micro-prediction.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
