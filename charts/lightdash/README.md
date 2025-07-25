# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 1.6.2](https://img.shields.io/badge/Version-1.6.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1121.0](https://img.shields.io/badge/AppVersion-0.1121.0-informational?style=flat-square)

## Prerequisites

### Backend Database

#### Using the Bitnami PostgreSQL chart

You may wish to use the Bitnami PostgreSQL chart to spin up a development environment. This guidance is for convenience, you'll want to [read the docs](https://github.com/bitnami/charts/tree/master/bitnami/postgresql/#installing-the-chart) before deciding how to implement PostgresSQL.

```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install lightdashdb bitnami/postgresql --set auth.username=lightdash,auth.password=changeme,auth.database=lightdash
```

Note, a persistent volume claim is created called `data-lightdashdb-postgresql-0` is created at invocation of the above. It is not deleted if `helm uninstall` is called.

Use `--set primary.persistence.enabled=false` to skip creating a persistent volume claim(for development purposes only).

## Installing Lightdash

```
helm repo add lightdash https://lightdash.github.io/helm-charts
helm install lightdash lightdash/lightdash \
  --set configMap.PGHOST=lightdashdb-postgresql.default.svc.cluster.local \
  --set secrets.PGPASSWORD=changeme \

```

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| https://charts.bitnami.com/bitnami | common | 1.x.x |
| https://charts.bitnami.com/bitnami | postgresql | 11.x.x |
| https://charts.sagikazarmark.dev | browserless-chrome | 0.0.4 |

## Values

Note The `secret.*` values are used to create [kubernetes secrets](https://kubernetes.io/docs/concepts/configuration/secret/).
If you don't want helm to manage this, you may wish to separately create a secret named `<release-name>-lightdash`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `100` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| backendConfig.create | bool | `false` |  |
| browserless-chrome.enabled | bool | `true` |  |
| browserless-chrome.env.CONNECTION_TIMEOUT | string | `"180000"` |  |
| browserless-chrome.image.repository | string | `"ghcr.io/browserless/chromium"` |  |
| browserless-chrome.image.tag | string | `"v2.24.3"` |  |
| browserless-chrome.replicaCount | int | `1` |  |
| browserless-chrome.resources.limits.cpu | string | `"500m"` |  |
| browserless-chrome.resources.limits.memory | string | `"512Mi"` |  |
| browserless-chrome.resources.requests.cpu | string | `"500m"` |  |
| browserless-chrome.resources.requests.memory | string | `"512Mi"` |  |
| browserless-chrome.service.port | int | `80` |  |
| configMap.DBT_PROJECT_DIR | string | `""` | Path to your local dbt project. Only set this value if you are mounting a DBT project |
| configMap.PORT | string | `"8080"` | Port for lightdash |
| configMap.SECURE_COOKIES | string | `"false"` | Secure Cookies |
| configMap.SITE_URL | string | `""` | Public URL of your instance including protocol e.g. https://lightdash.myorg.com |
| configMap.TRUST_PROXY | string | `"false"` | Trust the reverse proxy when setting secure cookies (via the "X-Forwarded-Proto" header) |
| externalDatabase.database | string | `"lightdash"` |  |
| externalDatabase.existingSecret | string | `""` |  |
| externalDatabase.host | string | `"localhost"` |  |
| externalDatabase.password | string | `""` |  |
| externalDatabase.port | int | `5432` |  |
| externalDatabase.secretKeys.passwordKey | string | `"postgresql-password"` |  |
| externalDatabase.user | string | `"lightdash"` |  |
| extraContainers | list | `[]` |  |
| extraEnv | list | `[]` |  |
| extraObjects | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| global.imageRegistry | string | `""` |  |
| global.storageClass | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"lightdash/lightdash"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.tls | list | `[]` |  |
| initContainers | list | `[]` |  |
| lightdashBackend.livenessProbe.initialDelaySeconds | int | `10` |  |
| lightdashBackend.livenessProbe.periodSeconds | int | `10` |  |
| lightdashBackend.livenessProbe.timeoutSeconds | int | `5` |  |
| lightdashBackend.readinessProbe.initialDelaySeconds | int | `35` |  |
| lightdashBackend.readinessProbe.periodSeconds | int | `35` |  |
| lightdashBackend.readinessProbe.timeoutSeconds | int | `30` |  |
| lightdashBackend.terminationGracePeriodSeconds | int | `90` |  |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| postgresql.auth.database | string | `"lightdash"` |  |
| postgresql.auth.existingSecret | string | `""` |  |
| postgresql.auth.password | string | `""` |  |
| postgresql.auth.secretKeys.userPasswordKey | string | `"password"` |  |
| postgresql.auth.username | string | `"lightdash"` |  |
| postgresql.commonAnnotations."helm.sh/hook" | string | `"pre-install,pre-upgrade"` |  |
| postgresql.commonAnnotations."helm.sh/hook-weight" | string | `"-1"` |  |
| postgresql.enabled | bool | `true` |  |
| queryWorker.concurrency | int | `3` |  |
| queryWorker.db.maxConnections | string | `nil` |  |
| queryWorker.enabled | bool | `false` |  |
| queryWorker.livenessProbe.initialDelaySeconds | int | `10` |  |
| queryWorker.livenessProbe.periodSeconds | int | `10` |  |
| queryWorker.livenessProbe.timeoutSeconds | int | `5` |  |
| queryWorker.port | int | `8080` |  |
| queryWorker.readinessProbe.initialDelaySeconds | int | `35` |  |
| queryWorker.readinessProbe.periodSeconds | int | `35` |  |
| queryWorker.readinessProbe.timeoutSeconds | int | `30` |  |
| queryWorker.replicas | int | `1` |  |
| queryWorker.resources.requests.cpu | string | `"475m"` |  |
| queryWorker.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| queryWorker.resources.requests.memory | string | `"725Mi"` |  |
| queryWorker.tasks.exclude | string | `nil` |  |
| queryWorker.tasks.include | string | `"runAsyncWarehouseQuery"` |  |
| queryWorker.terminationGracePeriodSeconds | int | `90` |  |
| replicaCount | int | `1` | Specify the number of lightdash instances. |
| resources | object | `{}` |  |
| scheduler.concurrency | int | `3` |  |
| scheduler.db.maxConnections | string | `nil` |  |
| scheduler.enabled | bool | `false` |  |
| scheduler.livenessProbe.initialDelaySeconds | int | `10` |  |
| scheduler.livenessProbe.periodSeconds | int | `10` |  |
| scheduler.livenessProbe.timeoutSeconds | int | `5` |  |
| scheduler.port | int | `8080` |  |
| scheduler.readinessProbe.initialDelaySeconds | int | `35` |  |
| scheduler.readinessProbe.periodSeconds | int | `35` |  |
| scheduler.readinessProbe.timeoutSeconds | int | `30` |  |
| scheduler.replicas | int | `1` |  |
| scheduler.resources.requests.cpu | string | `"475m"` |  |
| scheduler.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scheduler.resources.requests.memory | string | `"725Mi"` |  |
| scheduler.tasks.exclude | string | `"runAsyncWarehouseQuery"` |  |
| scheduler.tasks.include | string | `nil` |  |
| scheduler.terminationGracePeriodSeconds | int | `90` |  |
| schedulerExtraEnv | list | `[]` |  |
| secrets.LIGHTDASH_SECRET | string | `"changeme"` | This is the secret used to sign the session ID cookie and to encrypt sensitive information. Do not share this secret! |
| securityContext | object | `{}` |  |
| service.port | int | `8080` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| tolerations | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.7.0](https://github.com/norwoodj/helm-docs/releases/v1.7.0)
