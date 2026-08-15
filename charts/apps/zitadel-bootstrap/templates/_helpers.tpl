{{- define "zitadel-bootstrap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "zitadel-bootstrap.fullname" -}}
{{- include "zitadel-bootstrap.name" . }}
{{- end }}

{{- define "zitadel-bootstrap.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{- define "zitadel-bootstrap.labels" -}}
helm.sh/chart: {{ include "zitadel-bootstrap.name" . }}
app.kubernetes.io/name: {{ include "zitadel-bootstrap.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: identity-bootstrap
app.kubernetes.io/part-of: zitadel
{{- end }}

{{- define "zitadel-bootstrap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zitadel-bootstrap.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "zitadel-bootstrap.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "zitadel-bootstrap.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
