{{- define "marketplace-common.deployment" -}}
{{- if not .Values.knative.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "marketplace-common.fullname" . }}
  labels:
    {{- include "marketplace-common.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 1 }}
  selector:
    matchLabels:
      {{- include "marketplace-common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "true"
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        traffic.sidecar.istio.io/excludeOutboundIPRanges: "169.254.169.254/32"
        traffic.sidecar.istio.io/excludeOutboundPorts: "4222,5432,6379"
      labels:
        {{- include "marketplace-common.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "marketplace-common.serviceAccountName" . }}
      imagePullSecrets:
        - name: ghcr-tesserix-secret
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default "latest" }}"
          ports:
            - name: http
              containerPort: {{ .Values.port }}
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{ include "marketplace-common.fullname" . }}-config
            - secretRef:
                name: {{ include "marketplace-common.fullname" . }}-secrets
                optional: true
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          startupProbe:
            httpGet:
              path: {{ .Values.healthPath }}
              port: {{ .Values.port }}
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: {{ .Values.probes.startup.failureThreshold }}
          readinessProbe:
            httpGet:
              path: {{ .Values.healthPath }}
              port: {{ .Values.port }}
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: {{ .Values.healthPath }}
              port: {{ .Values.port }}
            initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
            periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
            failureThreshold: 3
{{- end }}
{{- end }}
