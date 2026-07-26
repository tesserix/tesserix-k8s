{{- define "redpanda.name" -}}
redpanda
{{- end -}}

{{- define "redpanda.headless" -}}
redpanda-headless
{{- end -}}

{{- define "redpanda.labels" -}}
app.kubernetes.io/name: redpanda
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "redpanda.selectorLabels" -}}
app.kubernetes.io/name: redpanda
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Fully-qualified broker address for a given ordinal. */}}
{{- define "redpanda.brokerFQDN" -}}
{{- printf "%s-%d.%s.%s.svc.cluster.local" (include "redpanda.name" .ctx) .ordinal (include "redpanda.headless" .ctx) .ctx.Release.Namespace -}}
{{- end -}}
