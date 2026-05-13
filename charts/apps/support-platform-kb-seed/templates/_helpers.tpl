{{- define "kb-seed.name" -}}support-platform-kb-seed{{- end -}}

{{- define "kb-seed.labels" -}}
app.kubernetes.io/name: {{ include "kb-seed.name" . }}
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/component: kb-seed
{{- end -}}
