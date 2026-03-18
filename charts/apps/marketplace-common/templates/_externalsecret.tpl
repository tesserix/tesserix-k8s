{{- define "marketplace-common.externalsecret" -}}
{{- if .Values.externalSecrets.enabled }}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "marketplace-common.fullname" . }}-secrets
  labels:
    {{- include "marketplace-common.labels" . | nindent 4 }}
spec:
  refreshInterval: {{ .Values.externalSecrets.refreshInterval | default "15m" }}
  secretStoreRef:
    name: {{ .Values.externalSecrets.secretStoreRef | default "gcp-secret-store" }}
    kind: ClusterSecretStore
  target:
    name: {{ include "marketplace-common.fullname" . }}-secrets
    creationPolicy: Owner
  data:
    {{- if .Values.db.enabled }}
    - secretKey: DB_PASSWORD
      remoteRef:
        key: {{ .Values.db.secretKey }}
        version: latest
    {{- end }}
    {{- if and .Values.openfga.enabled .Values.openfga.apiKeySecret }}
    - secretKey: OPENFGA_API_KEY
      remoteRef:
        key: openfga-preshared-key
        version: latest
    {{- end }}
    - secretKey: INTERNAL_SERVICE_KEY
      remoteRef:
        key: shared-internal-service-key
        version: latest
    {{- range .Values.extraSecrets }}
    - secretKey: {{ .secretKey }}
      remoteRef:
        key: {{ .remoteKey }}
        version: latest
    {{- end }}
{{- end }}
{{- end }}
