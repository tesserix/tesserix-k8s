{{- define "marketplace-common.knative-service" -}}
{{- if .Values.knative.enabled }}
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: {{ include "marketplace-common.fullname" . }}
  labels:
    {{- include "marketplace-common.labels" . | nindent 4 }}
    networking.knative.dev/visibility: cluster-local
  annotations:
    networking.knative.dev/disableAutoTLS: "true"
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/class: kpa.autoscaling.knative.dev
        autoscaling.knative.dev/metric: concurrency
        autoscaling.knative.dev/target: {{ .Values.knative.concurrencyTarget | quote }}
        autoscaling.knative.dev/minScale: {{ .Values.knative.minScale | quote }}
        autoscaling.knative.dev/maxScale: {{ .Values.knative.maxScale | quote }}
        autoscaling.knative.dev/scale-to-zero-pod-retention-period: {{ .Values.knative.scaleToZeroDelay | default "0s" | quote }}
        autoscaling.knative.dev/window: {{ .Values.knative.stableWindow | default "60s" | quote }}
        autoscaling.knative.dev/initial-scale: {{ .Values.knative.initialScale | default "1" | quote }}
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
        traffic.sidecar.istio.io/excludeOutboundIPRanges: "169.254.169.254/32"
        traffic.sidecar.istio.io/excludeOutboundPorts: "4222,5432,6379"
      labels:
        {{- include "marketplace-common.labels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "marketplace-common.serviceAccountName" . }}
      containerConcurrency: {{ .Values.knative.containerConcurrency }}
      timeoutSeconds: {{ .Values.knative.timeoutSeconds }}
      imagePullSecrets:
        - name: ghcr-tesserix-secret
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default "latest" }}"
          ports:
            - containerPort: {{ .Values.port }}
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
