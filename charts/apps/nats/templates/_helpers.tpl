{{- define "nats.fullname" -}}
{{- default (printf "%s-nats" .Release.Namespace) .Values.fullnameOverride -}}
{{- end -}}

{{- define "nats.labels" -}}
app.kubernetes.io/name: nats
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: event-backbone
{{- end -}}

{{- define "nats.selectorLabels" -}}
app.kubernetes.io/name: nats
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
