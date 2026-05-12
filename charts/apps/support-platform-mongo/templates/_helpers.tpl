{{- define "support-platform-mongo.name" -}}
{{ .Values.name }}
{{- end }}

{{- define "support-platform-mongo.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: mongo
{{- end }}

{{- define "support-platform-mongo.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
