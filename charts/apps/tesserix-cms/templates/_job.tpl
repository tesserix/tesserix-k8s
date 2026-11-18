{{/*
Pod spec shared by the CLI Jobs (migrate, create-super-admin, seed). The Payload
CLI runs from /app/cli and needs a writable /tmp for tsx's cache.
Call with (dict "root" $ "name" "migrate" "script" "migrate" "serviceAccount" "" "env" (list ...)).
*/}}
{{- define "tesserix-cms.jobPod" -}}
{{- $root := .root -}}
restartPolicy: Never
{{- if .serviceAccount }}
serviceAccountName: {{ .serviceAccount }}
{{- end }}
automountServiceAccountToken: false
securityContext:
  {{- toYaml $root.Values.podSecurityContext | nindent 2 }}
containers:
  - name: {{ .name }}
    image: "{{ $root.Values.image.repository }}:{{ required "image.tag is required" $root.Values.image.tag }}"
    imagePullPolicy: {{ $root.Values.image.pullPolicy }}
    workingDir: /app/cli
    command: ["npm", "run", {{ .script | quote }}]
    securityContext:
      {{- toYaml $root.Values.securityContext | nindent 6 }}
    env:
      - name: NODE_ENV
        value: production
      # npm's cache and logs default to $HOME, which is read-only here.
      - name: npm_config_cache
        value: /tmp/.npm
      {{- range list "DATABASE_URL" "PAYLOAD_SECRET" }}
      - name: {{ . }}
        valueFrom:
          secretKeyRef:
            name: {{ $root.Values.secretName }}
            key: {{ . }}
      {{- end }}
      {{- with .env }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    volumeMounts:
      - name: tmp
        mountPath: /tmp
    resources:
      requests:
        memory: 256Mi
      limits:
        memory: 1Gi
volumes:
  - name: tmp
    emptyDir: {}
{{- end }}
