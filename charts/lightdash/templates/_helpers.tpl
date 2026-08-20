{{/*
Expand the name of the chart.
*/}}
{{- define "lightdash.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "lightdash.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod Anti-Affinity template that can be reused for different components
Provides hard node anti-affinity and soft zone anti-affinity for high availability
Usage: {{- include "lightdash.podAntiAffinity" (dict "root" . "component" "backend") }}
*/}}
{{- define "lightdash.podAntiAffinity" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- if $root.Values.podAntiAffinity.enabled }}
podAntiAffinity:
  {{- if or (eq $root.Values.podAntiAffinity.node "hard") (eq $root.Values.podAntiAffinity.zone "hard") }}
  requiredDuringSchedulingIgnoredDuringExecution:
    {{- if eq $root.Values.podAntiAffinity.node "hard" }}
    - labelSelector:
        matchLabels:
          {{- include "lightdash.selectorLabels" $root | nindent 10 }}
          app.kubernetes.io/component: {{ $component }}
      topologyKey: kubernetes.io/hostname
    {{- end }}
    {{- if eq $root.Values.podAntiAffinity.zone "hard" }}
    - labelSelector:
        matchLabels:
          {{- include "lightdash.selectorLabels" $root | nindent 10 }}
          app.kubernetes.io/component: {{ $component }}
      topologyKey: topology.kubernetes.io/zone
    {{- end }}
  {{- end }}
  {{- if or (eq $root.Values.podAntiAffinity.node "soft") (eq $root.Values.podAntiAffinity.zone "soft") }}
  preferredDuringSchedulingIgnoredDuringExecution:
    {{- if eq $root.Values.podAntiAffinity.node "soft" }}
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            {{- include "lightdash.selectorLabels" $root | nindent 12 }}
            app.kubernetes.io/component: {{ $component }}
        topologyKey: kubernetes.io/hostname
    {{- end }}
    {{- if eq $root.Values.podAntiAffinity.zone "soft" }}
    - weight: 50
      podAffinityTerm:
        labelSelector:
          matchLabels:
            {{- include "lightdash.selectorLabels" $root | nindent 12 }}
            app.kubernetes.io/component: {{ $component }}
        topologyKey: topology.kubernetes.io/zone
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "lightdash.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "lightdash.labels" -}}
helm.sh/chart: {{ include "lightdash.chart" . }}
{{ include "lightdash.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "lightdash.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lightdash.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
Create a default fully qualified postgresql name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "lightdash.postgresql.fullname" -}}
{{- $name := default "postgresql" .Values.postgresql.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{/*
Get the name of the postgresql credentials secret.
If postgres is enabled, subchart creates it's own secret containing the password unless the user specifies an existingSecret
If using an external database, strict secretRefs.database takes precedence, then externalDatabase.existingSecret,
otherwise the password will be stored in a Secret created by this chart.
*/}}
{{- define "lightdash.database.secretName" -}}
{{- if .Values.postgresql.enabled -}}
    {{- if .Values.postgresql.auth.existingSecret -}}
        {{ .Values.postgresql.auth.existingSecret -}}
    {{- else -}}
        {{- include "lightdash.postgresql.fullname" . -}}
    {{- end -}}
{{- else if .Values.secretRefs.enabled -}}
    {{ required "secretRefs.database.name is required when secretRefs.enabled=true and postgresql.enabled=false" .Values.secretRefs.database.name -}}
{{- else -}}
    {{- if .Values.externalDatabase.existingSecret -}}
        {{ .Values.externalDatabase.existingSecret -}}
    {{- else -}}
        {{- printf "%s-externaldb" (include "lightdash.fullname" .) -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{- define "lightdash.database.secret.passwordKey" -}}
{{- if .Values.postgresql.enabled -}}
  {{- ternary "password" .Values.postgresql.auth.secretKeys.userPasswordKey (eq "" .Values.postgresql.auth.existingSecret) -}}
{{- else if .Values.secretRefs.enabled -}}
  {{- .Values.secretRefs.database.passwordKey | default "PGPASSWORD" -}}
{{- else -}}
  {{- .Values.externalDatabase.secretKeys.passwordKey -}}
{{- end -}}
{{- end -}}

{{/*
Render Secret envFrom entries for a Lightdash workload. Strict mode gives the
backend and workers only the application Secret and gives the migration Job only
its migration Secret. Otherwise preserve the legacy selection rules.
*/}}
{{- define "lightdash.secretEnvFrom" -}}
{{- $root := .root -}}
{{- $migration := .migration -}}
{{- if $root.Values.secretRefs.enabled }}
{{- if $migration }}
{{- if $root.Values.secretRefs.migration.name }}
- secretRef:
    name: {{ $root.Values.secretRefs.migration.name }}
{{- else if not $root.Values.migrationJob.extraEnv }}
{{- fail "secretRefs.migration.name is required when secretRefs.enabled=true and migrationJob.enabled=true. The migration Job receives neither the application nor the S3 Secret, but Lightdash reads LIGHTDASH_SECRET while loading its config, so the Job cannot start without it. Point secretRefs.migration.name at a Secret containing LIGHTDASH_SECRET (the same Secret as secretRefs.application.name is fine), or supply it through migrationJob.extraEnv." }}
{{- end }}
{{- else }}
- secretRef:
    name: {{ required "secretRefs.application.name is required when secretRefs.enabled=true" $root.Values.secretRefs.application.name }}
{{- end }}
{{- else if $migration }}
{{- if and $root.Values.migrationJob.inheritGlobalEnv $root.Values.existingSecret }}
- secretRef:
    name: {{ $root.Values.existingSecret }}
{{- end }}
{{- if $root.Values.migrationJob.existingSecret }}
- secretRef:
    name: {{ $root.Values.migrationJob.existingSecret }}
{{- else if not (empty $root.Values.secrets) }}
- secretRef:
    name: {{ include "lightdash.fullname" $root }}-migration-secrets
{{- end }}
{{- if $root.Values.s3.existingSecret }}
- secretRef:
    name: {{ $root.Values.s3.existingSecret }}
{{- end }}
{{- else }}
{{- if $root.Values.existingSecret }}
- secretRef:
    name: {{ $root.Values.existingSecret }}
{{- else if $root.Values.secrets }}
- secretRef:
    name: {{ include "lightdash.fullname" $root }}
{{- end }}
{{- if $root.Values.s3.existingSecret }}
- secretRef:
    name: {{ $root.Values.s3.existingSecret }}
{{- else if or $root.Values.s3.accessKey $root.Values.s3.secretKey }}
- secretRef:
    name: {{ include "lightdash.fullname" $root }}-s3
{{- end }}
{{- end }}
{{- end -}}

{{/*
Render only the two S3 credential environment variables from the strict S3
Secret. This avoids exposing unrelated keys through envFrom.
*/}}
{{- define "lightdash.s3SecretEnvs" -}}
{{- if and .Values.secretRefs.enabled .Values.secretRefs.s3.name }}
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretRefs.s3.name }}
      key: {{ .Values.secretRefs.s3.accessKey | default "S3_ACCESS_KEY" }}
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretRefs.s3.name }}
      key: {{ .Values.secretRefs.s3.secretKey | default "S3_SECRET_KEY" }}
{{- end }}
{{- end -}}

{{/*
Validate that S3 storage is configured. Keys can also arrive through a Secret this
chart cannot inspect: existingSecret in legacy mode, secretRefs.application.name in
strict mode. Either one is accepted as evidence that the keys are supplied.
*/}}
{{- define "lightdash.validateS3Config" -}}
{{- $configMap := .Values.configMap -}}
{{- $secrets := ternary (dict) .Values.secrets .Values.secretRefs.enabled -}}
{{- $s3 := .Values.s3 -}}
{{- $hasOpaqueSecret := ternary .Values.secretRefs.application.name .Values.existingSecret .Values.secretRefs.enabled -}}
{{- $hasEndpoint := or $s3.endpoint $configMap.S3_ENDPOINT $secrets.S3_ENDPOINT $hasOpaqueSecret -}}
{{- $hasBucket := or $s3.bucket $configMap.S3_BUCKET $secrets.S3_BUCKET $hasOpaqueSecret -}}
{{- $hasRegion := or $s3.region $configMap.S3_REGION $secrets.S3_REGION $hasOpaqueSecret -}}
{{- if not (and $hasEndpoint $hasBucket $hasRegion) -}}
{{- $sources := ternary "configMap or the Secret named by secretRefs.application.name" "configMap, secrets, or existingSecret" .Values.secretRefs.enabled -}}
{{- fail (printf "S3-compatible storage is required. Set s3.endpoint, s3.bucket, and s3.region, or provide S3_ENDPOINT, S3_BUCKET, and S3_REGION through %s. See https://docs.lightdash.com/self-host/customize-deployment/environment-variables#s3" $sources) -}}
{{- end -}}
{{- end -}}

{{/*
Configuration for postgres credentials
*/}}
{{- define "lightdash.database.host" -}}
{{- ternary (include "lightdash.postgresql.fullname" .) .Values.externalDatabase.host .Values.postgresql.enabled -}}
{{- end -}}

{{- define "lightdash.database.user" -}}
{{- ternary .Values.postgresql.auth.username .Values.externalDatabase.user .Values.postgresql.enabled -}}
{{- end -}}

{{- define "lightdash.database.name" -}}
{{- ternary .Values.postgresql.auth.database .Values.externalDatabase.database .Values.postgresql.enabled -}}
{{- end -}}

{{- define "lightdash.database.password" -}}
{{- ternary .Values.postgresql.auth.password .Values.externalDatabase.password .Values.postgresql.enabled -}}
{{- end -}}

{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.port" -}}
{{- ternary "5432" .Values.externalDatabase.port .Values.postgresql.enabled -}}
{{- end -}}

{{/*
 Create the name of the service account to use
 */}}
{{- define "lightdash.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{- .Values.serviceAccount.name | default (include "lightdash.fullname" .) -}}
{{- else -}}
    {{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "lightdash.backendReadinessProbePath" -}}
{{- $configuredPath := .Values.lightdashBackend.readinessProbe.path -}}
{{- if $configuredPath -}}
{{- $configuredPath -}}
{{- else -}}
{{- $imageTag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- $version := trimPrefix "v" $imageTag -}}
{{- $semanticVersionPattern := `^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$` -}}
{{- $isSemanticVersion := regexMatch $semanticVersionPattern $version -}}
{{- $isPrerelease := regexMatch `^[0-9]+\.[0-9]+\.[0-9]+-` $version -}}
{{- if and $isSemanticVersion (not $isPrerelease) (semverCompare ">=1.169.1" $version) -}}
/api/v1/readyz
{{- else -}}
/api/v1/health
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
 Name of the service account used by the migration hook Job
 */}}
{{- define "lightdash.migrationServiceAccountName" -}}
{{- if .Values.migrationJob.serviceAccount.create -}}
    {{- .Values.migrationJob.serviceAccount.name | default (printf "%s-migration" (include "lightdash.fullname" .)) -}}
{{- else -}}
    {{- .Values.migrationJob.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}


{{/*
 Create the name of the backend configuration
 */}}
{{- define "lightdash.backendConfigName" -}}
{{- if .Values.backendConfig.create -}}
    {{- .Values.backendConfig.name | default (include "lightdash.fullname" .) -}}
{{- else -}}
    {{- .Values.backendConfig.name | default "default" -}}
{{- end -}}
{{- end -}}

{{/*
Create a default fully qualified headless browser name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "lightdash.headlessBrowser.fullname" -}}
{{- $name := default "browserless-chrome" (index .Values "browserless-chrome").nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Create the host and port of the headless browser
*/}}
{{- define "lightdash.headlessBrowser.host" -}}
    {{- ternary (include "lightdash.headlessBrowser.fullname" .) "" (index .Values "browserless-chrome").enabled -}}
{{- end -}}
{{- define "lightdash.headlessBrowser.port" -}}
    {{- printf ((index .Values "browserless-chrome").service.port | toString) -}}
{{- end -}}

{{/*
Renders environment variables for SSL if enabled.
*/}}
{{- define "lightdash.sslEnvs" -}}
{{- if .Values.ssl.enabled -}}
- name: PGSSLMODE
  value: verify-full
- name: NODE_EXTRA_CA_CERTS
  value: {{ .Values.ssl.mountPath }}/{{ .Values.ssl.certFileName }}
{{- end -}}
{{- end -}}

{{/*
Renders a volume for the SSL certificate ConfigMap if ssl.enabled is true.
*/}}
{{- define "lightdash.sslConfigMapVolume" -}}
{{- if .Values.ssl.enabled -}}
- name: ssl-cert
  configMap:
    name: {{ .Values.ssl.configMapName | default (printf "%s-ssl-cert" (include "lightdash.fullname" .)) }}
    items:
      - key: {{ .Values.ssl.certFileName }}
        path: {{ .Values.ssl.certFileName }}
{{- end -}}
{{- end -}}

{{/*
Renders a volumeMount for the SSL certificate if ssl.enabled is true.
*/}}
{{- define "lightdash.sslConfigMapVolumeMount" -}}
{{- if .Values.ssl.enabled -}}
- name: ssl-cert
  mountPath: {{ .Values.ssl.mountPath }}/{{ .Values.ssl.certFileName }}
  subPath: {{ .Values.ssl.certFileName }}
  readOnly: true
{{- end -}}
{{- end -}}

{{/*
SSL env vars for the migration Job: migrationJob.ssl when enabled, else top-level ssl.
*/}}
{{- define "lightdash.migrationJobSslEnvs" -}}
{{- if .Values.migrationJob.ssl.enabled -}}
- name: PGSSLMODE
  value: verify-full
- name: NODE_EXTRA_CA_CERTS
  value: {{ .Values.migrationJob.ssl.mountPath }}/{{ .Values.migrationJob.ssl.certFileName }}
{{- else if .Values.ssl.enabled -}}
- name: PGSSLMODE
  value: verify-full
- name: NODE_EXTRA_CA_CERTS
  value: {{ .Values.ssl.mountPath }}/{{ .Values.ssl.certFileName }}
{{- end -}}
{{- end -}}

{{/*
Volume mount for the migration Job SSL cert: migrationJob.ssl when enabled, else ssl.
*/}}
{{- define "lightdash.migrationJobSslVolumeMount" -}}
{{- if .Values.migrationJob.ssl.enabled -}}
- name: ssl-cert
  mountPath: {{ .Values.migrationJob.ssl.mountPath }}/{{ .Values.migrationJob.ssl.certFileName }}
  subPath: {{ .Values.migrationJob.ssl.certFileName }}
  readOnly: true
{{- else if .Values.ssl.enabled -}}
{{- include "lightdash.sslConfigMapVolumeMount" . }}
{{- end -}}
{{- end -}}

{{/*
Volume for the migration Job SSL cert ConfigMap: migrationJob.ssl when enabled, else ssl.
*/}}
{{- define "lightdash.migrationJobSslVolume" -}}
{{- if .Values.migrationJob.ssl.enabled -}}
- name: ssl-cert
  configMap:
    name: {{ .Values.migrationJob.ssl.configMapName | default (printf "%s-migration-ssl-cert" (include "lightdash.fullname" .)) }}
    items:
      - key: {{ .Values.migrationJob.ssl.certFileName }}
        path: {{ .Values.migrationJob.ssl.certFileName }}
{{- else if .Values.ssl.enabled -}}
{{- include "lightdash.sslConfigMapVolume" . }}
{{- end -}}
{{- end -}}

{{/*
Pod Disruption Budget template that can be reused for different components
Usage: {{- include "lightdash.podDisruptionBudget" (dict "root" . "component" "backend" "pdbConfig" .Values.podDisruptionBudget) }}
*/}}
{{- define "lightdash.podDisruptionBudget" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $pdbConfig := .pdbConfig -}}
{{- if $pdbConfig.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "lightdash.fullname" $root }}-{{ $component }}
  labels:
    {{- include "lightdash.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $component }}
spec:
  {{- if and (hasKey $pdbConfig "minAvailable") (not (kindIs "invalid" $pdbConfig.minAvailable)) }}
  minAvailable: {{ $pdbConfig.minAvailable }}
  {{- else if and (hasKey $pdbConfig "maxUnavailable") (not (kindIs "invalid" $pdbConfig.maxUnavailable)) }}
  maxUnavailable: {{ $pdbConfig.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "lightdash.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $component }}
{{- end }}
{{- end }}

{{/*
Create a default fully qualified NATS name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "lightdash.nats.fullname" -}}
{{- $name := default "nats" .Values.nats.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create the NATS URL for connecting to JetStream
*/}}
{{- define "lightdash.nats.url" -}}
{{- if .Values.nats.enabled -}}
nats://{{ include "lightdash.nats.fullname" . }}:4222
{{- end -}}
{{- end -}}
