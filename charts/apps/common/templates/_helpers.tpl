{{/*
Common helper templates for tesserix services.
*/}}

{{/*
Generate common labels.
Usage: {{ include "common.labels" (dict "name" "my-service" "chart" .Chart "release" .Release) }}
*/}}
{{- define "common.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .chart.Name .chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .release.Name }}
app.kubernetes.io/version: {{ .chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .release.Service }}
{{- end -}}

{{/*
Generate selector labels.
Usage: {{ include "common.selectorLabels" (dict "name" "my-service" "release" .Release) }}
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .release.Name }}
{{- end -}}

{{/*
Generate database host based on namespace pattern.
Usage: {{ include "common.databaseHost" . }}
*/}}
{{- define "common.databaseHost" -}}
{{- if .Values.database.host }}
{{- .Values.database.host }}
{{- else if .Values.database.namespace }}
postgresql.{{ .Values.database.namespace }}.svc.cluster.local
{{- else }}
postgresql.postgresql-{{ .Values.gcp.namespace | default .Release.Namespace }}.svc.cluster.local
{{- end }}
{{- end -}}

{{/*
Generate Redis host based on namespace pattern.
Usage: {{ include "common.redisHost" . }}
*/}}
{{- define "common.redisHost" -}}
{{- if and .Values.redis .Values.redis.host }}
{{- .Values.redis.host }}
{{- else if and .Values.redis .Values.redis.namespace }}
redis-master.{{ .Values.redis.namespace }}.svc.cluster.local
{{- else }}
redis-master.redis-{{ .Values.gcp.namespace | default .Release.Namespace }}.svc.cluster.local
{{- end }}
{{- end -}}

{{/*
Generate global service URL.
Usage: {{ include "common.globalServiceUrl" (dict "serviceName" "auth-service" "port" "8080") }}
*/}}
{{- define "common.globalServiceUrl" -}}
http://{{ .serviceName }}.global.svc.cluster.local:{{ .port }}
{{- end -}}

{{/*
Generate service URL in same namespace.
Usage: {{ include "common.serviceUrl" (dict "serviceName" "products-service" "port" "8080" "namespace" .Release.Namespace) }}
*/}}
{{- define "common.serviceUrl" -}}
http://{{ .serviceName }}.{{ .namespace }}.svc.cluster.local:{{ .port }}
{{- end -}}

{{/*
Common pod annotations including Istio configuration.
Usage: {{ include "common.podAnnotations" . | nindent 8 }}
*/}}
{{- define "common.podAnnotations" -}}
proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
{{- if .Values.istio.excludeOutboundPorts }}
traffic.sidecar.istio.io/excludeOutboundPorts: {{ .Values.istio.excludeOutboundPorts | quote }}
{{- else }}
traffic.sidecar.istio.io/excludeOutboundPorts: "4222,5432,6379,8080"
{{- end }}
{{- with .Values.podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Standard resource limits.
Usage: {{ include "common.resources" . | nindent 12 }}
*/}}
{{- define "common.resources" -}}
{{- if .Values.resources }}
{{- toYaml .Values.resources }}
{{- else }}
limits:
  memory: 512Mi
requests:
  memory: 128Mi
{{- end }}
{{- end -}}
