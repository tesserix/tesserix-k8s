{{- define "mcp-stub.name" -}}
{{ .Values.tenant }}-mcp
{{- end -}}

{{- define "mcp-stub.labels" -}}
app.kubernetes.io/name: {{ include "mcp-stub.name" . }}
app.kubernetes.io/instance: {{ include "mcp-stub.name" . }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: mcp-stub
mcp.tesserix.app/tenant: {{ .Values.tenant }}
{{- end -}}

{{- define "mcp-stub.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-stub.name" . }}
{{- end -}}
