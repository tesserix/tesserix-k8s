{{- define "document-intelligence.labels" -}}
app.kubernetes.io/name: document-intelligence
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: document-intelligence
app.kubernetes.io/managed-by: {{ .Release.Service }}
tesserix.io/product: {{ .Values.product }}
{{- end }}

{{- define "document-intelligence.image" -}}
{{ printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end }}

{{/* Every per-product resource name derives from product + environment; the same convention is in terraform-new/stacks/15-document-intelligence-products. Explicit values win so legacy kora releases keep their names. */}}
{{- define "document-intelligence.config" -}}
{{- $p := required "product is required" .Values.product -}}
{{- $e := required "environment is required" .Values.environment -}}
{{- $scope := ternary $p (printf "%s-%s" $p (ternary "development" $e (eq $e "dev"))) (eq $e "prod") -}}
{{- $reader := printf "openbao-%s-%s" $p (ternary "production" (ternary "development" $e (eq $e "dev")) (eq $e "prod")) -}}
{{- $name := .Values.fullname | default (printf "document-intelligence-%s-%s" $p $e) -}}
{{- $defaults := dict
  "fullname" $name
  "temporal" (dict "namespace" $name "taskQueue" $name)
  "buckets" (dict
    "quarantine" (printf "%s-%s-doc-quarantine-in" $p $e)
    "source" (printf "%s-%s-doc-accepted-in" $p $e)
    "pages" (printf "%s-%s-doc-derived-in" $p $e)
    "results" (printf "%s-%s-doc-results-in" $p $e))
  "serviceAccounts" (dict
    "upload" (printf "%s-%s-ocr-signer" $p $e)
    "jobs" (printf "%s-%s-ocr-reader" $p $e)
    "dispatch" (printf "%s-%s-ocr-scanner" $p $e)
    "execution" (printf "%s-%s-ocr-worker" $p $e))
  "database" (dict
    "secretName" (printf "%s-db" $name)
    "openbaoKey" (printf "%s/app/%s-document-intelligence-db-password" $scope $p)
    "openbaoStore" $reader
    "user" (printf "document_intelligence_%s_%s" $p $e)
    "name" (printf "document_intelligence_%s_%s_db" $p $e))
  "identity" (dict "secretName" (printf "%s-api-identity" $name) "openbaoKey" (printf "%s/app/%s-ocr-workload-identity-keys" $scope $p) "openbaoStore" $reader)
  "apiClientNamespaces" (list)
  "apiClientPrincipals" (list) -}}
{{- range .Values.clients }}
{{- $_ := set $defaults "apiClientNamespaces" (append $defaults.apiClientNamespaces .namespace | uniq) }}
{{- $_ := set $defaults "apiClientPrincipals" (append $defaults.apiClientPrincipals (printf "cluster.local/ns/%s/sa/%s" .namespace .serviceAccount)) }}
{{- end }}
{{- $explicit := pick (deepCopy .Values) "temporal" "buckets" "serviceAccounts" "database" "identity" "apiClientNamespaces" "apiClientPrincipals" -}}
{{- $config := mergeOverwrite $defaults $explicit -}}
{{- range list $config.database $config.identity }}
{{- if eq (.secretBackend | default "openbao") "gcp" }}
{{- $_ := unset . "openbaoKey" -}}
{{- $_ := unset . "openbaoStore" -}}
{{- end }}
{{- end }}
{{- $config | toYaml }}
{{- end }}

{{- define "document-intelligence.fullname" -}}
{{ (include "document-intelligence.config" . | fromYaml).fullname }}
{{- end }}

{{- define "document-intelligence.secretSource" -}}
{{- if .openbaoKey }}
sourceRef:
  storeRef:
    name: {{ required "openbaoStore is required with openbaoKey" .openbaoStore }}
    kind: SecretStore
remoteRef:
  key: {{ .openbaoKey | quote }}
  property: value
{{- else }}
remoteRef:
  key: {{ required "Explicit legacy GCP secretManagerKey or OpenBao key/store is required" .secretManagerKey | quote }}
{{- end }}
{{- end }}
