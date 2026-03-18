{{/*
tesserix-blog helpers
*/}}

{{- define "common.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "common.podAnnotations" -}}
proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
traffic.sidecar.istio.io/excludeOutboundIPRanges: "169.254.169.254/32"
{{- end -}}

{{- define "common.serviceAccount" -}}
{{ .Release.Name }}
{{- end -}}
