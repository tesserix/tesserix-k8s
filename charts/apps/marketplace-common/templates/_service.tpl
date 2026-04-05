{{- define "marketplace-common.service" -}}
{{- if not .Values.knative.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "marketplace-common.fullname" . }}
  labels:
    {{- include "marketplace-common.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.servicePort | default 8080 }}
      protocol: TCP
      targetPort: {{ .Values.port }}
  selector:
    {{- include "marketplace-common.selectorLabels" . | nindent 4 }}
{{- end }}
{{- end }}
