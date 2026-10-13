{{- define "kora-ai-gateway.labels" -}}
app.kubernetes.io/name: kora-ai-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kora-ai
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "kora-ai-gateway.aiRoutes" -}}
/v1/chat/completions: Completions
/v1/embeddings: Embeddings
'*': Detect
{{- end -}}

{{- define "kora-ai-gateway.userJwtAuthentication" -}}
jwtAuthentication:
  mode: Strict
  location:
    header:
      name: {{ .Values.endUserAuthentication.header }}
      prefix: "Bearer "
  providers:
    - issuer: {{ .Values.endUserAuthentication.issuer }}
      audiences:
        - {{ .Values.endUserAuthentication.audience | quote }}
      jwks:
        remote:
          jwksPath: {{ .Values.endUserAuthentication.jwksPath }}
          cacheDuration: {{ .Values.endUserAuthentication.jwksCacheDuration }}
          backendRef:
            group: agentgateway.dev
            kind: AgentgatewayBackend
            name: kora-firebase-jwks
            port: 443
    {{- range .Values.endUserAuthentication.extraIssuers }}
    - issuer: {{ .issuer }}
      audiences:
        - {{ .audience | quote }}
      jwks:
        remote:
          jwksPath: {{ .jwksPath }}
          cacheDuration: {{ $.Values.endUserAuthentication.jwksCacheDuration }}
          backendRef:
            group: agentgateway.dev
            kind: AgentgatewayBackend
            name: {{ .jwksBackend }}
            port: 443
    {{- end }}
{{- end -}}

{{- define "kora-ai-gateway.vertexGroup" -}}
- providers:
    - name: vertex
      vertexai:
        projectId: {{ .root.Values.providers.vertex.projectId }}
        region: {{ .root.Values.providers.vertex.region }}
        model: {{ .model }}
      policies:
        auth:
          gcp: {}
        tls: {}
{{- end -}}

{{- define "kora-ai-gateway.anthropicGroup" -}}
- providers:
    - name: anthropic
      anthropic:
        model: {{ default .Values.providers.anthropic.model .anthropicModel }}
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

{{- define "kora-ai-gateway.usageMetadata" -}}
ledger_capability: '"x-kora-ai-capability" in request.headers ? request.headers["x-kora-ai-capability"] : ""'
ledger_user: '"x-kora-user-id" in request.headers ? request.headers["x-kora-user-id"] : ""'
ledger_service: '"x-kora-ai-service" in request.headers ? request.headers["x-kora-ai-service"] : ""'
ledger_agent_id: '"x-kora-agent-id" in request.headers ? request.headers["x-kora-agent-id"] : ""'
ledger_agent_version: '"x-kora-agent-version" in request.headers ? request.headers["x-kora-agent-version"] : ""'
ledger_agent_run_id: '"x-kora-agent-run-id" in request.headers ? request.headers["x-kora-agent-run-id"] : ""'
{{- end }}
