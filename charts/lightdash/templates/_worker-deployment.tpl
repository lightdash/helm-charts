{{/*
Worker deployment template that can be reused for different scheduler components
Usage: {{- include "lightdash.workerDeployment" (dict "root" . "component" "worker" "workerConfig" .Values.scheduler) }}
*/}}
{{- define "lightdash.workerDeployment" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $workerConfig := .workerConfig -}}
{{- $volumes := $workerConfig.extraVolumes }}
{{- $volumeMounts := $workerConfig.extraVolumeMounts }}
{{- if $workerConfig.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "lightdash.fullname" $root }}-{{ $component }}
  labels:
    {{- include "lightdash.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $component }}
spec:
  replicas: {{ $workerConfig.replicas }}
  selector:
    matchLabels:
      {{- include "lightdash.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $component }}
  template:
    metadata:
      annotations:
        {{- with $root.Values.podAnnotations }}
          {{- toYaml . | nindent 8 }}
        {{- end }}
        checksum/config: {{ include (print $root.Template.BasePath "/configmap.yaml") $root | sha256sum }}
        checksum/secrets: {{ include (print $root.Template.BasePath "/secrets.yaml") $root | sha256sum }}
      labels:
        {{- with $root.Values.podLabels }}
          {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- include "lightdash.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ $component }}
    spec:
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml $root.Values.podSecurityContext | nindent 8 }}
      serviceAccountName: {{ include "lightdash.serviceAccountName" $root }}
      containers:
        {{- if $root.Values.extraContainers }}
          {{- toYaml $root.Values.extraContainers | nindent 8 }}
        {{- end }}
        - name: {{ $root.Chart.Name }}
          securityContext:
            {{- toYaml $root.Values.securityContext | nindent 12 }}
          image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag | default $root.Chart.AppVersion }}"
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          command: {{ $workerConfig.command | default (list "node" "dist/scheduler.js") | toJson }}
          args: {{ $root.Values.image.args }}
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ (include "lightdash.database.secretName" $root) }}
                  key: {{ (include "lightdash.database.secret.passwordKey" $root) }}
            - name: PORT
              value: {{ $workerConfig.port | quote }}
            {{- if and $workerConfig.tasks $workerConfig.tasks.include }}
            - name: SCHEDULER_INCLUDE_TASKS
              value: "{{ $workerConfig.tasks.include }}"
            {{- end }}
            {{- if and $workerConfig.tasks $workerConfig.tasks.exclude }}
            - name: SCHEDULER_EXCLUDE_TASKS
              value: "{{ $workerConfig.tasks.exclude }}"
            {{- end }}
            {{- if eq ($workerConfig.type | default "graphile") "nats" }}
            - name: NATS_WORKER_CONCURRENCY
              value: {{ $workerConfig.concurrency | default 3 | quote }}
            {{- else }}
            - name: SCHEDULER_CONCURRENCY
              value: {{ $workerConfig.concurrency | default 3 | quote }}
            {{- if $workerConfig.pollInterval }}
            - name: SCHEDULER_POLL_INTERVAL
              value: {{ $workerConfig.pollInterval | quote }}
            {{- end }}
            {{- end }}
            {{- if $workerConfig.db.maxConnections }}
            - name: PGMAXCONNECTIONS
              value: {{ $workerConfig.db.maxConnections | quote }}
            {{- end }}
            {{- if $root.Values.extraEnv }}
            {{- toYaml $root.Values.extraEnv | nindent 12 }}
            {{- end }}
            {{- if $root.Values.schedulerExtraEnv }}
            {{- toYaml $root.Values.schedulerExtraEnv | nindent 12 }}
            {{- end }}
          envFrom:
            - configMapRef:
                name: {{ template "lightdash.fullname" $root }}
            {{- if $root.Values.secrets }}
            - secretRef:
                name: {{ template "lightdash.fullname" $root }}
            {{- end }}
          {{- if $workerConfig.startupProbe }}
          startupProbe:
            {{- if $workerConfig.startupProbe.initialDelaySeconds }}
            initialDelaySeconds: {{ $workerConfig.startupProbe.initialDelaySeconds }}
            {{- end }}
            {{- if $workerConfig.startupProbe.timeoutSeconds }}
            timeoutSeconds: {{ $workerConfig.startupProbe.timeoutSeconds }}
            {{- end }}
            {{- if $workerConfig.startupProbe.periodSeconds }}
            periodSeconds: {{ $workerConfig.startupProbe.periodSeconds }}
            {{- end }}
            {{- if $workerConfig.startupProbe.failureThreshold }}
            failureThreshold: {{ $workerConfig.startupProbe.failureThreshold }}
            {{- end }}
            {{- if $workerConfig.startupProbe.successThreshold }}
            successThreshold: {{ $workerConfig.startupProbe.successThreshold }}
            {{- end }}
            httpGet:
              path: {{ $workerConfig.startupProbe.path | default "/api/v1/livez" }}
              port: {{ $workerConfig.port }}
          {{- end }}
          livenessProbe:
            {{- if $workerConfig.livenessProbe.initialDelaySeconds }}
            initialDelaySeconds: {{ $workerConfig.livenessProbe.initialDelaySeconds }}
            {{- end }}
            {{- if $workerConfig.livenessProbe.timeoutSeconds }}
            timeoutSeconds: {{ $workerConfig.livenessProbe.timeoutSeconds }}
            {{- end }}
            {{- if $workerConfig.livenessProbe.periodSeconds }}
            periodSeconds: {{ $workerConfig.livenessProbe.periodSeconds }}
            {{- end }}
            {{- if $workerConfig.livenessProbe.failureThreshold }}
            failureThreshold: {{ $workerConfig.livenessProbe.failureThreshold }}
            {{- end }}
            {{- if $workerConfig.livenessProbe.successThreshold }}
            successThreshold: {{ $workerConfig.livenessProbe.successThreshold }}
            {{- end }}
            httpGet:
              path: {{ $workerConfig.livenessProbe.path | default "/api/v1/health" }}
              port: {{ $workerConfig.port }}
          readinessProbe:
            {{- if $workerConfig.readinessProbe.initialDelaySeconds }}
            initialDelaySeconds: {{ $workerConfig.readinessProbe.initialDelaySeconds }}
            {{- end }}
            {{- if $workerConfig.readinessProbe.timeoutSeconds }}
            timeoutSeconds: {{ $workerConfig.readinessProbe.timeoutSeconds }}
            {{- end }}
            {{- if $workerConfig.readinessProbe.periodSeconds }}
            periodSeconds: {{ $workerConfig.readinessProbe.periodSeconds }}
            {{- end }}
            {{- if $workerConfig.readinessProbe.failureThreshold }}
            failureThreshold: {{ $workerConfig.readinessProbe.failureThreshold }}
            {{- end }}
            {{- if $workerConfig.readinessProbe.successThreshold }}
            successThreshold: {{ $workerConfig.readinessProbe.successThreshold }}
            {{- end }}
            httpGet:
              path: {{ $workerConfig.readinessProbe.path | default "/api/v1/health" }}
              port: {{ $workerConfig.port }}
          resources:
            {{- toYaml $workerConfig.resources | nindent 12 }}
          {{- if or $volumeMounts $root.Values.ssl.enabled }}
          volumeMounts:
            {{- if $volumeMounts }}
            {{- toYaml $volumeMounts | nindent 12 }}
            {{- end }}
            {{- include "lightdash.sslConfigMapVolumeMount" $root | nindent 12 }}
          {{- end }}
      {{- if or $volumes $root.Values.ssl.enabled }}
      volumes:
        {{- if $volumes }}
        {{- toYaml $volumes | nindent 8 }}
        {{- end }}
        {{- include "lightdash.sslConfigMapVolume" $root | nindent 8 }}
      {{- end }}
      {{- if $root.Values.initContainers }}
      initContainers:
        {{- toYaml $root.Values.initContainers | nindent 8 }}
      {{- end }} 
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if or $root.Values.podAntiAffinity.enabled $root.Values.affinity }}
      affinity:
        {{- include "lightdash.podAntiAffinity" (dict "root" $root "component" $component) | nindent 8 }}
        {{- with $root.Values.affinity }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: {{ $workerConfig.terminationGracePeriodSeconds | default 90 }}
      {{- with $root.Values.dnsConfig }}
      dnsConfig:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.dnsPolicy }}
      dnsPolicy: {{ . }}
      {{- end }}
{{- end }}
{{- end }}
