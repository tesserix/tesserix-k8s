{{- define "gip-admin-claims.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: identity-platform
app.kubernetes.io/component: admin-claims-sync
{{- end }}
