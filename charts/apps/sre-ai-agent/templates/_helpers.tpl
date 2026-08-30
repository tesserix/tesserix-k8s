{{- define "sre-ai-agent.labels" -}}
app.kubernetes.io/name: sre-ai-agent
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: ai-agents
app.kubernetes.io/component: sre-agent
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "sre-ai-agent.selectorLabels" -}}
app.kubernetes.io/name: sre-ai-agent
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sre-ai-agent.image" -}}
{{- $digest := required "image.digest is required when sre-ai-agent is enabled" .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end }}
