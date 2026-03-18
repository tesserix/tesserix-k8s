{{/*
Expand the name of the chart.
*/}}
{{- define "kargo-project.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kargo-project.fullname" -}}
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
{{- define "kargo-project.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kargo-project.labels" -}}
helm.sh/chart: {{ include "kargo-project.chart" . }}
{{ include "kargo-project.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kargo-project.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kargo-project.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Get the project name
*/}}
{{- define "kargo-project.projectName" -}}
{{- .Values.project.name | default .Release.Name }}
{{- end }}

{{/*
Get the image repository URL for a service
*/}}
{{- define "kargo-project.imageRepo" -}}
{{- $registry := .root.Values.registry }}
{{- printf "%s/%s/%s/%s" $registry.url $registry.owner $registry.repoPrefix .service.imageRepo }}
{{- end }}
