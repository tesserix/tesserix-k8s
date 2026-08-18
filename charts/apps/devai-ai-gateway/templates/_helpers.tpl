{{- define "devai-ai-gateway.labels" -}}
app.kubernetes.io/name: devai-ai-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devai
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "devai-ai-gateway.passthrough" -}}
policies:
  auth:
    passthrough: {}
  tls: {}
{{- end -}}
