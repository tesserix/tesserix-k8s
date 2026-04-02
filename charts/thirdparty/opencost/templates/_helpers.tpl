{{/*
Common labels
*/}}
{{- define "opencost.labels" -}}
app.kubernetes.io/name: opencost
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/component: cost-monitoring
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
OpenCost selector labels
*/}}
{{- define "opencost.selectorLabels" -}}
app.kubernetes.io/name: opencost
app.kubernetes.io/instance: {{ .Release.Name }}
app: opencost
{{- end }}

{{/*
OAuth2 Proxy selector labels
*/}}
{{- define "oauth2-proxy.selectorLabels" -}}
app.kubernetes.io/name: oauth2-proxy
app.kubernetes.io/instance: {{ .Release.Name }}
app: oauth2-proxy
{{- end }}
