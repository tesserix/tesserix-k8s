{{/*
Chart name
*/}}
{{- define "db-schema-bootstrap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname: <app>-db-schema-bootstrap
*/}}
{{- define "db-schema-bootstrap.fullname" -}}
{{- printf "%s-db-schema-bootstrap" .Values.app | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "db-schema-bootstrap.labels" -}}
helm.sh/chart: {{ include "db-schema-bootstrap.name" . }}
app.kubernetes.io/name: {{ include "db-schema-bootstrap.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: db-bootstrap
app.kubernetes.io/part-of: {{ .Values.app }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "db-schema-bootstrap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "db-schema-bootstrap.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "db-schema-bootstrap.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "db-schema-bootstrap.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "db-schema-bootstrap.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{/*
A target is named after its database, and a database may hold an underscore.
Object and volume names are RFC 1123, so they get the hyphenated form.
*/}}
{{- define "db-schema-bootstrap.targetSlug" -}}
{{- . | replace "_" "-" | lower }}
{{- end }}
