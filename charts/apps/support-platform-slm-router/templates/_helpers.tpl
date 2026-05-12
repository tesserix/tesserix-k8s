{{- define "support-platform-slm-router.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: slm-router
{{- end }}

{{- define "support-platform-slm-router.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
