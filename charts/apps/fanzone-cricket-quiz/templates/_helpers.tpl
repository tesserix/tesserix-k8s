{{/*
Expand the name of the chart.
*/}}
{{- define "fanzone-cricket-quiz.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fanzone-cricket-quiz.fullname" -}}
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
{{- define "fanzone-cricket-quiz.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fanzone-cricket-quiz.labels" -}}
helm.sh/chart: {{ include "fanzone-cricket-quiz.chart" . }}
{{ include "fanzone-cricket-quiz.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fanzone-battle-ground
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fanzone-cricket-quiz.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fanzone-cricket-quiz.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: cricket-quiz
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fanzone-cricket-quiz.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fanzone-cricket-quiz.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
