{{- define "export.name" -}}support-platform-export{{- end -}}

{{- define "export.labels" -}}
app.kubernetes.io/name: {{ include "export.name" . }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: export
{{- end -}}
