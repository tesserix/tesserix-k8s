{{/*
Create a default fully qualified app name.
*/}}
{{- define "photon.fullname" -}}
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
Create the name of the service account to use
*/}}
{{- define "photon.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "photon.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "photon.labels" -}}
app.kubernetes.io/name: photon
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: geocoding
app.kubernetes.io/part-of: tesseract-hub
{{- end }}

{{/*
Selector labels
*/}}
{{- define "photon.selectorLabels" -}}
app.kubernetes.io/name: photon
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
