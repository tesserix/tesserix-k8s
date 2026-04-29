{{- define "social-platform-api.dbEnv" -}}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.secretName }}
      key: username
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.secretName }}
      key: password
- name: DATABASE_URL
  value: "postgres://$(DB_USER):$(DB_PASSWORD)@{{ .Values.database.host }}:{{ .Values.database.port }}/{{ .Values.database.name }}?sslmode={{ .Values.database.sslmode }}"
{{- end -}}
