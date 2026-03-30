{{- define "marketplace-common.direct-service" -}}
{{- if .Values.knative.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "marketplace-common.fullname" . }}-direct
  labels:
    {{- include "marketplace-common.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.directServicePort | default .Values.port }}
      protocol: TCP
      targetPort: {{ .Values.port }}
  selector:
    serving.knative.dev/service: {{ include "marketplace-common.fullname" . }}
{{- end }}
{{- end }}
