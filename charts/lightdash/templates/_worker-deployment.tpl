{{/*
Worker deployment template that can be reused for different scheduler components
Usage: {{- include "lightdash.workerDeployment" (dict "root" . "component" "worker" "workerConfig" .Values.scheduler) }}
*/}}
{{- define "lightdash.workerDeployment" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $workerConfig := .workerConfig -}}
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
          command: ["node", "dist/scheduler.js"]
          args: {{ $root.Values.image.args }}
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ (include "lightdash.database.secretName" $root) }}
                  key: {{ (include "lightdash.database.secret.passwordKey" $root) }}
            - name: PORT
              value: {{ $workerConfig.port | quote }}
            {{- if $workerConfig.tasks.include }}
            - name: SCHEDULER_INCLUDE_TASKS
              value: "{{ $workerConfig.tasks.include }}"
            {{- end }}
            {{- if $workerConfig.tasks.exclude }}
            - name: SCHEDULER_EXCLUDE_TASKS
              value: "{{ $workerConfig.tasks.exclude }}"
            {{- end }}
            - name: SCHEDULER_CONCURRENCY
              value: {{ $workerConfig.concurrency | default 3 | quote }}
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
          livenessProbe:
            initialDelaySeconds: {{ $workerConfig.livenessProbe.initialDelaySeconds }}
            timeoutSeconds: {{ $workerConfig.livenessProbe.timeoutSeconds }}
            periodSeconds: {{ $workerConfig.livenessProbe.periodSeconds }}
            httpGet:
              path: /api/v1/health
              port: {{ $workerConfig.port }}
          readinessProbe:
            initialDelaySeconds: {{ $workerConfig.readinessProbe.initialDelaySeconds }}
            periodSeconds: {{ $workerConfig.readinessProbe.periodSeconds }}
            timeoutSeconds: {{ $workerConfig.readinessProbe.timeoutSeconds }}
            httpGet:
              path: /api/v1/health
              port: {{ $workerConfig.port }}
          resources:
            {{- toYaml $workerConfig.resources | nindent 12 }}
      {{- if $root.Values.initContainers }}
      initContainers:
        {{- toYaml $root.Values.initContainers | nindent 8 }}
      {{- end }} 
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: {{ $workerConfig.terminationGracePeriodSeconds | default 90 }}
{{- end }}
{{- end }}
