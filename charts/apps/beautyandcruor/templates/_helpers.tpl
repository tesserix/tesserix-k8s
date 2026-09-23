{{/*
beautyandcruor helpers.

These intentionally SHADOW the like-named templates in the `common` library
chart. The library versions take an explicit dict
(`dict "name" ... "chart" .Chart "release" .Release`); every app chart in this
repo redefines them to take the root context instead, so templates can call
`include "common.labels" .`. Deleting this file does not fall back to the
library — it fails to render with a nil pointer on `.chart.Name`.
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

{{/*
holdApplicationUntilProxyStarts matters even for a static site: without it the
container can accept traffic before the sidecar is ready and the first requests
after a rollout fail.

The metadata-server exclusion is kept for consistency with the other charts
even though this pod uses no Workload Identity — it costs nothing and removing
it would be a surprise if a future revision ever does need GCP access.
*/}}
{{- define "common.podAnnotations" -}}
proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
traffic.sidecar.istio.io/excludeOutboundIPRanges: "169.254.169.254/32"
{{- end -}}

{{- define "common.serviceAccount" -}}
{{ .Release.Name }}
{{- end -}}
