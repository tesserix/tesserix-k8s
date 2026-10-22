{{- define "civiclens-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "civiclens-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "civiclens-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "civiclens-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: civiclens
{{- end }}

{{- define "civiclens-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "civiclens-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "civiclens-api.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ required "Kargo must set image.tag or image.digest" .Values.image.tag }}
{{- end -}}
{{- end -}}

{{- define "civiclens-api.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "civiclens-api.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "civiclens-api.configVolumes" -}}
- name: config
  secret:
    secretName: {{ .secret }}
    defaultMode: 0440
- name: postgres-ca
  secret:
    secretName: {{ .values.database.caSecret }}
    defaultMode: 0440
    items:
      - key: ca.crt
        path: ca.crt
{{- end -}}

{{- define "civiclens-api.configMounts" -}}
- name: config
  mountPath: /var/run/civiclens/secrets
  readOnly: true
- name: postgres-ca
  mountPath: /var/run/civiclens/database-ca
  readOnly: true
{{- end -}}

{{- define "civiclens-api.configEnv" -}}
- name: CIVICLENS_SECRETS_FILE
  value: /var/run/civiclens/secrets/secrets.json
- name: PGSSLROOTCERT
  value: /var/run/civiclens/database-ca/ca.crt
{{- end -}}
