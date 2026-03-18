{{- define "marketplace-common.configmap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "marketplace-common.fullname" . }}-config
  labels:
    {{- include "marketplace-common.labels" . | nindent 4 }}
data:
  {{- if eq .Values.serviceType "go" }}
  ENVIRONMENT: "production"
  {{- if .Values.gcp.projectId }}
  GCP_PROJECT_ID: {{ .Values.gcp.projectId | quote }}
  {{- end }}
  {{- if .Values.db.enabled }}
  DB_HOST: {{ .Values.db.host | quote }}
  DB_PORT: {{ .Values.db.port | quote }}
  DB_NAME: {{ .Values.db.name | quote }}
  DB_USER: {{ .Values.db.user | quote }}
  DB_SSLMODE: {{ .Values.db.sslmode | quote }}
  {{- end }}
  SERVICE_AUTH_MODE: "mesh"
  {{- if .Values.openfga.enabled }}
  OPENFGA_URL: {{ .Values.openfga.url | quote }}
  OPENFGA_AUTH_MODE: {{ .Values.openfga.authMode | quote }}
  {{- if .Values.openfga.storeId }}
  OPENFGA_MARKETPLACE_STORE_ID: {{ .Values.openfga.storeId | quote }}
  {{- end }}
  {{- end }}
  {{- else if eq .Values.serviceType "nextjs" }}
  NODE_ENV: "production"
  {{- if .Values.gcp.projectId }}
  GCP_PROJECT_ID: {{ .Values.gcp.projectId | quote }}
  {{- end }}
  {{- end }}
  {{- range $key, $value := .Values.env }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
{{- end }}
