{{- define "support-platform-slm-inference.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: slm-inference
{{- end }}

{{- define "support-platform-slm-inference.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
