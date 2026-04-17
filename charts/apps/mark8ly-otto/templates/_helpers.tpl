{{- define "mark8ly-otto.name" -}}
{{ .Values.name }}
{{- end }}

{{- define "mark8ly-otto.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: mark8ly
app.kubernetes.io/component: support-chat
{{- end }}

{{- define "mark8ly-otto.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
