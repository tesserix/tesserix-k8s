{{- define "local-infra.labels" -}}
app.kubernetes.io/name: local-infra
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: local-infra
{{- end -}}

{{- define "local-infra.pgHost" -}}
{{ .Values.cnpg.clusterName }}-rw.{{ .Values.namespace }}.svc.cluster.local
{{- end -}}
