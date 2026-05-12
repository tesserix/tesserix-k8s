{{- define "support-platform-otto.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: chat
{{- end }}

{{- define "support-platform-otto.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
