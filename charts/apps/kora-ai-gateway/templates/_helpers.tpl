{{- define "kora-ai-gateway.labels" -}}
app.kubernetes.io/name: kora-ai-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kora-ai
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "kora-ai-gateway.vertexGroup" -}}
- providers:
    - name: vertex
      host: aiplatform.googleapis.com
      port: 443
      vertexai:
        projectId: {{ .root.Values.providers.vertex.projectId }}
        region: {{ .root.Values.providers.vertex.region }}
        model: {{ .model }}
      policies:
        auth:
          gcp: {}
          credentials:
            - secretRef:
                name: {{ .root.Values.externalSecrets.providerSecretName }}
                key: vertex-api-key
              location:
                header:
                  name: x-goog-api-key
        tls: {}
{{- end -}}

{{- define "kora-ai-gateway.anthropicGroup" -}}
- providers:
    - name: anthropic
      anthropic:
        model: {{ .Values.providers.anthropic.model }}
      policies:
        auth:
          secretRef:
            name: {{ .Values.externalSecrets.providerSecretName }}
            key: anthropic
{{- end -}}

{{- define "kora-ai-gateway.xaiGroup" -}}
- providers:
    - name: xai
      host: {{ .Values.providers.xai.host }}
      port: 443
      pathPrefix: /v1
      openai:
        model: {{ .Values.providers.xai.model }}
      policies:
        auth:
          secretRef:
            name: {{ .Values.externalSecrets.providerSecretName }}
            key: xai
        tls: {}
{{- end -}}
