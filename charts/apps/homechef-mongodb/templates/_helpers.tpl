{{- define "homechef-mongodb.name" -}}
{{ .Values.name }}
{{- end }}

{{- define "homechef-mongodb.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: homechef
app.kubernetes.io/component: mongo
{{- end }}

{{- define "homechef-mongodb.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}
