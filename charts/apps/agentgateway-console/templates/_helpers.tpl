{{- define "agentgateway-console.name" -}}
{{ .Values.name }}
{{- end -}}

{{- define "agentgateway-console.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/component: gateway
app.kubernetes.io/part-of: agentgateway
{{- end -}}
