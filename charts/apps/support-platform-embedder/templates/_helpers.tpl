{{- define "support-platform-embedder.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: embedder
{{- end }}

{{- define "support-platform-embedder.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
