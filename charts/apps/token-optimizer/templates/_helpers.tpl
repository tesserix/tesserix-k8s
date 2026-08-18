{{- define "token-optimizer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "token-optimizer.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "token-optimizer.name" . -}}
{{- end -}}
{{- end -}}

{{- define "token-optimizer.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "token-optimizer.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kora-ai
{{- end -}}

{{- define "token-optimizer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "token-optimizer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "token-optimizer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "token-optimizer.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when create is false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

