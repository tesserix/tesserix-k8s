{{- define "mcp-gateway.name" -}}
{{ .Values.tenant }}-mcp
{{- end -}}

{{- define "mcp-gateway.labels" -}}
app.kubernetes.io/name: {{ include "mcp-gateway.name" . }}
app.kubernetes.io/instance: {{ include "mcp-gateway.name" . }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: mcp-gateway
mcp.tesserix.app/tenant: {{ .Values.tenant }}
{{- end -}}

{{- define "mcp-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-gateway.name" . }}
{{- end -}}
