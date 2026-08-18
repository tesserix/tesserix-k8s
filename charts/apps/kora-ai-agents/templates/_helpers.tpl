{{- define "kora-ai-agents.labels" -}}
app.kubernetes.io/name: kora-ai-agents
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kora
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "kora-ai-agents.selectorLabels" -}}
app.kubernetes.io/name: kora-ai-agents
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "kora-ai-agents.image" -}}
{{- if .Values.image.digest -}}
{{ printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end -}}
{{- end }}

