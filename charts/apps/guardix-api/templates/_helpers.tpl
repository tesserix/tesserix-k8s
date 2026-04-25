{{- define "guardix-api.name" -}}
{{- .Values.name | default "guardix-api" -}}
{{- end -}}

{{- define "guardix-api.labels" -}}
{{ include "common.labels" (dict "name" (include "guardix-api.name" .) "chart" .Chart "release" .Release) }}
{{- end -}}

{{- define "guardix-api.selectorLabels" -}}
{{ include "common.selectorLabels" (dict "name" (include "guardix-api.name" .) "release" .Release) }}
{{- end -}}

{{- define "guardix-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "guardix-api.name" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
