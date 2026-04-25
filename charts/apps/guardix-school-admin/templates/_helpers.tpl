{{- define "guardix-school-admin.name" -}}
{{- .Values.name | default "guardix-school-admin" -}}
{{- end -}}

{{- define "guardix-school-admin.labels" -}}
{{ include "common.labels" (dict "name" (include "guardix-school-admin.name" .) "chart" .Chart "release" .Release) }}
{{- end -}}

{{- define "guardix-school-admin.selectorLabels" -}}
{{ include "common.selectorLabels" (dict "name" (include "guardix-school-admin.name" .) "release" .Release) }}
{{- end -}}

{{- define "guardix-school-admin.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "guardix-school-admin.name" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
