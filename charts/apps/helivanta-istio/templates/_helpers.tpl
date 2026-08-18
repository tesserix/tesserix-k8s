{{- define "helivanta-istio.labels" -}}
app.kubernetes.io/name: helivanta-istio
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: helivanta
app.kubernetes.io/component: routing
{{- end -}}
