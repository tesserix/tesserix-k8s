{{/*
Expand the name of the chart.
*/}}
{{- define "fanzone-user.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fanzone-user.fullname" -}}
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
{{- define "fanzone-user.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fanzone-user.labels" -}}
helm.sh/chart: {{ include "fanzone-user.chart" . }}
{{ include "fanzone-user.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fanzone-battle-ground
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fanzone-user.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fanzone-user.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: user
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fanzone-user.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fanzone-user.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the configmap to use
*/}}
{{- define "fanzone-user.configMapName" -}}
{{- include "fanzone-user.fullname" . }}-config
{{- end }}
