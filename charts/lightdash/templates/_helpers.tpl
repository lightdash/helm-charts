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
Get the Postgresql credentials secret.
*/}}
{{- define "lightdash.postgresql.secretName" -}}
{{- if and (.Values.postgresql.enabled) (not .Values.postgresql.auth.existingSecret) -}}
    {{- printf "%s" (include "lightdash.postgresql.fullname" .) -}}
{{- else if and (.Values.postgresql.enabled) (.Values.postgresql.auth.existingSecret) -}}
    {{- printf "%s" .Values.postgresql.auth.existingSecret -}}
{{- else }}
    {{- if .Values.externalDatabase.existingSecret -}}
        {{- printf "%s" .Values.externalDatabase.existingSecret -}}
    {{- else -}}
        {{ printf "%s-%s" .Release.Name "externaldb" }}
    {{- end -}}
{{- end -}}
{{- end -}}


{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.host" -}}
{{- ternary (include "lightdash.postgresql.fullname" .) .Values.externalDatabase.host .Values.postgresql.enabled -}}
{{- end -}}

{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.user" -}}
{{- ternary .Values.postgresql.auth.username .Values.externalDatabase.user .Values.postgresql.enabled -}}
{{- end -}}

{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.name" -}}
{{- ternary .Values.postgresql.auth.database .Values.externalDatabase.database .Values.postgresql.enabled -}}
{{- end -}}

{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.existingsecret.key" -}}
{{- if .Values.postgresql.enabled -}}
    {{- printf "%s" "postgresql-password" -}}
{{- else -}}
    {{- if .Values.externalDatabase.existingSecret -}}
        {{- if .Values.externalDatabase.existingSecretPasswordKey -}}
            {{- printf "%s" .Values.externalDatabase.existingSecretPasswordKey -}}
        {{- else -}}
            {{- printf "%s" "postgresql-password" -}}
        {{- end -}}
    {{- else -}}
        {{- printf "%s" "postgresql-password" -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.port" -}}
{{- ternary "5432" .Values.externalDatabase.port .Values.postgresql.enabled -}}
{{- end -}}

{{/*
Add environment variables to configure database values
*/}}
{{- define "lightdash.database.url" -}}
{{- $host := (include "lightdash.database.host" .) -}}
{{- $dbName := (include "lightdash.database.name" .) -}}
{{- $port := (include "lightdash.database.port" . ) -}}
{{- printf "jdbc:postgresql://%s:%s/%s" $host $port $dbName -}}
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
