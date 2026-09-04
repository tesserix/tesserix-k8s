{{- define "document-intelligence.labels" -}}
app.kubernetes.io/name: document-intelligence
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: document-intelligence
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "document-intelligence.image" -}}
{{ printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end }}
{{- define "document-intelligence.fullname" -}}
{{ printf "document-intelligence-%s" .Values.environment }}
{{- end }}
