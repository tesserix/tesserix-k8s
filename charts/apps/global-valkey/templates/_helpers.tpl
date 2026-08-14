{{- define "global-valkey.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "global-valkey.labels" -}}
app.kubernetes.io/name: {{ include "global-valkey.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: global
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "global-valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "global-valkey.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "global-valkey.headless" -}}
{{ include "global-valkey.name" . }}-headless
{{- end -}}

{{- define "global-valkey.primaryName" -}}
{{ include "global-valkey.name" . }}
{{- end -}}

{{- define "global-valkey.haproxyConfig" -}}
global
  maxconn 4000
  log stdout format raw local0 info
defaults
  mode tcp
  timeout connect 4s
  timeout client 30s
  timeout server 30s
  log global
# Only the node reporting role:master passes this check, so a Sentinel
# promotion moves traffic without the client knowing.
listen valkey
  bind *:{{ .Values.haproxy.port }}
  option tcp-check
{{- if .Values.acl.enabled }}
  tcp-check send AUTH\ healthcheck\ x\r\n
  tcp-check expect string +OK
{{- end }}
  tcp-check send PING\r\n
  tcp-check expect string +PONG
  tcp-check send info\ replication\r\n
  tcp-check expect string role:master
  tcp-check send QUIT\r\n
  tcp-check expect string +OK
{{- $root := . }}
{{- range $i := until (int .Values.replicaCount) }}
  server valkey-{{ $i }} {{ include "global-valkey.name" $root }}-{{ $i }}.{{ include "global-valkey.headless" $root }}.{{ $root.Release.Namespace }}.svc.cluster.local:{{ $root.Values.valkey.port }} check inter 2s fall 2 rise 2 resolvers kube init-addr none
{{- end }}
resolvers kube
  nameserver dns kube-dns.kube-system.svc.cluster.local:53
  resolve_retries 3
  timeout retry 1s
  hold valid 5s
{{- end -}}

{{/* FQDN of pod N of the StatefulSet. Sentinel and replication both need a
     stable address that survives rescheduling, which only the headless
     service provides. */}}
{{- define "global-valkey.podFQDN" -}}
{{- $root := index . 0 -}}
{{- $ordinal := index . 1 -}}
{{ include "global-valkey.name" $root }}-{{ $ordinal }}.{{ include "global-valkey.headless" $root }}.{{ $root.Release.Namespace }}.svc.cluster.local
{{- end -}}
