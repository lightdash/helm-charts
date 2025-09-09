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
If using an external database, the password will be stored in the lightdash secret unless the user specifies an existingSecret
*/}}
{{- define "lightdash.database.secretName" -}}
{{- if .Values.postgresql.enabled -}}
    {{- if .Values.postgresql.auth.existingSecret -}}
        {{ .Values.postgresql.auth.existingSecret -}}
    {{- else -}}
        {{- include "lightdash.postgresql.fullname" . -}}
    {{- end -}}
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
{{- else -}}
  {{- .Values.externalDatabase.secretKeys.passwordKey -}}
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
