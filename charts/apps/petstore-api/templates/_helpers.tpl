{{/*
Expand the name of the chart.
*/}}
{{- define "petstore-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "petstore-api.fullname" -}}
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
{{- define "petstore-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "petstore-api.labels" -}}
helm.sh/chart: {{ include "petstore-api.chart" . }}
{{ include "petstore-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: petstore
{{- end }}

{{/*
Selector labels
*/}}
{{- define "petstore-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petstore-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "petstore-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "petstore-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the container port
*/}}
{{- define "petstore-api.containerPort" -}}
{{- .Values.service.targetPort | default 3000 }}
{{- end }}

{{/*
Create common environment variables
*/}}
{{- define "petstore-api.commonEnv" -}}
- name: NODE_ENV
  value: {{ .Values.env.NODE_ENV | quote }}
- name: PORT
  value: {{ include "petstore-api.containerPort" . | quote }}
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}

{{/*
Create secret environment variables
*/}}
{{- define "petstore-api.secretEnv" -}}
{{- range .Values.envFromSecrets }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ .key }}
      optional: {{ .optional | default false }}
{{- end }}
{{- end }}