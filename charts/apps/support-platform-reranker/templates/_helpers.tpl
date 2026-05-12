{{- define "support-platform-reranker.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: reranker
{{- end }}

{{- define "support-platform-reranker.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
