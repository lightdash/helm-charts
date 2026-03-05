# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 2.3.0](https://img.shields.io/badge/Version-2.3.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.2248.0](https://img.shields.io/badge/AppVersion-0.2248.0-informational?style=flat-square)

## Prerequisites

### Backend Database

#### PostgreSQL with Vector Extension Support

**Important**: Lightdash now requires PostgreSQL with the `vector` extension for embedding and advanced search functionality. This chart automatically uses the `pgvector/pgvector` Docker image which includes the required extension.

#### Using External PostgreSQL

If you want to use your own PostgreSQL instance, ensure it has the vector extension available!

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
| https://nats-io.github.io/k8s/helm/charts/ | nats | 2.12.4 |
| https://charts.bitnami.com/bitnami | postgresql | 11.x.x |
| https://charts.sagikazarmark.dev | browserless-chrome | 0.0.5 |

## High Availability

### Pod Anti-Affinity

To ensure high availability during node maintenance or failures, you can enable pod anti-affinity rules that spread pods across different nodes and availability zones.

```yaml
podAntiAffinity:
  enabled: true
  node: hard  # Pods MUST be on different nodes
  zone: soft  # Pods PREFER different zones (but won't fail scheduling if unavailable)
```

**Options:**
- `hard`: Required constraint - scheduling will fail if it cannot be satisfied
- `soft`: Preferred constraint - scheduler will try but won't fail if unsatisfied
- `none`: Disable the constraint

**Recommended configuration:**
- `node: hard` + `zone: soft` - Guarantees node separation, prefers zone separation
- This prevents downtime during GKE node maintenance while avoiding scheduling failures when zones are limited

**Note:** Anti-affinity is namespace-scoped by default, so pods from different namespaces can share nodes.

### Pod Disruption Budget

A Pod Disruption Budget is enabled by default to prevent all pods from being evicted simultaneously during voluntary disruptions:

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

**Important:** PDBs only work effectively when combined with multiple replicas. With `replicaCount: 1`, the PDB cannot prevent downtime.

## NATS JetStream (Optional)

You can deploy a per-release NATS dependency and bootstrap JetStream resources directly from this chart.

Minimal enablement:

```yaml
nats:
  enabled: true

natsJetstream:
  enabled: true
```

By default, the chart configures:
- Stream: `QUERY_JOBS` on subject `query.jobs`
- Durable consumer: `async-query-workers`
- Bootstrap Job: post-install/post-upgrade Helm hook (idempotent create/update)
- JetStream memory store mode (no persistence)

If `natsJetstream.connection.url` is empty and `nats.enabled=true`, the chart computes a local URL in the same namespace.

You can configure authentication using either:
- Static values (`natsJetstream.connection.user/password/token`), stored in chart-managed Secret
- Existing Secret (`natsJetstream.connection.existingSecret` + `secretKeys`)

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
| browserless-chrome.image.tag | string | `"v2.38.2"` |  |
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
| lightdashBackend.extraVolumeMounts | list | `[]` |  |
| lightdashBackend.extraVolumes | list | `[]` |  |
| lightdashBackend.livenessProbe.failureThreshold | int | `6` |  |
| lightdashBackend.livenessProbe.initialDelaySeconds | int | `5` |  |
| lightdashBackend.livenessProbe.periodSeconds | int | `15` |  |
| lightdashBackend.livenessProbe.timeoutSeconds | int | `15` |  |
| lightdashBackend.readinessProbe.failureThreshold | int | `2` |  |
| lightdashBackend.readinessProbe.initialDelaySeconds | int | `5` |  |
| lightdashBackend.readinessProbe.periodSeconds | int | `5` |  |
| lightdashBackend.readinessProbe.timeoutSeconds | int | `5` |  |
| lightdashBackend.startupProbe.failureThreshold | int | `18` |  |
| lightdashBackend.startupProbe.initialDelaySeconds | int | `5` |  |
| lightdashBackend.startupProbe.periodSeconds | int | `10` |  |
| lightdashBackend.startupProbe.timeoutSeconds | int | `10` |  |
| lightdashBackend.terminationGracePeriodSeconds | int | `90` |  |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podAntiAffinity.enabled | bool | `false` |  |
| podAntiAffinity.node | string | `"hard"` |  |
| podAntiAffinity.zone | string | `"soft"` |  |
| podDisruptionBudget.enabled | bool | `true` |  |
| podDisruptionBudget.minAvailable | int | `1` |  |
| podLabels | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| postgresql.auth.database | string | `"lightdash"` |  |
| postgresql.auth.existingSecret | string | `""` |  |
| postgresql.auth.password | string | `""` |  |
| postgresql.auth.secretKeys.userPasswordKey | string | `"password"` |  |
| postgresql.auth.username | string | `"lightdash"` |  |
| postgresql.commonAnnotations."helm.sh/hook" | string | `"pre-install,pre-upgrade"` |  |
| postgresql.commonAnnotations."helm.sh/hook-weight" | string | `"-1"` |  |
| postgresql.enabled | bool | `true` |  |
| postgresql.image.registry | string | `"docker.io"` |  |
| postgresql.image.repository | string | `"pgvector/pgvector"` |  |
| postgresql.image.tag | string | `"pg16"` |  |
| preAggregateQueryWorker.concurrency | int | `4` |  |
| preAggregateQueryWorker.db.maxConnections | string | `nil` |  |
| preAggregateQueryWorker.enabled | bool | `false` |  |
| preAggregateQueryWorker.extraVolumeMounts | list | `[]` |  |
| preAggregateQueryWorker.extraVolumes | list | `[]` |  |
| preAggregateQueryWorker.livenessProbe.failureThreshold | int | `20` |  |
| preAggregateQueryWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| preAggregateQueryWorker.livenessProbe.periodSeconds | int | `15` |  |
| preAggregateQueryWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| preAggregateQueryWorker.pollInterval | string | `nil` |  |
| preAggregateQueryWorker.port | int | `8080` |  |
| preAggregateQueryWorker.readinessProbe.failureThreshold | int | `2` |  |
| preAggregateQueryWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| preAggregateQueryWorker.readinessProbe.periodSeconds | int | `5` |  |
| preAggregateQueryWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| preAggregateQueryWorker.replicas | int | `1` |  |
| preAggregateQueryWorker.resources.requests.cpu | string | `"475m"` |  |
| preAggregateQueryWorker.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| preAggregateQueryWorker.resources.requests.memory | string | `"725Mi"` |  |
| preAggregateQueryWorker.startupProbe.failureThreshold | int | `18` |  |
| preAggregateQueryWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| preAggregateQueryWorker.startupProbe.periodSeconds | int | `10` |  |
| preAggregateQueryWorker.startupProbe.timeoutSeconds | int | `10` |  |
| preAggregateQueryWorker.tasks.exclude | string | `nil` |  |
| preAggregateQueryWorker.tasks.include | string | `"runAsyncPreAggregateQuery"` |  |
| preAggregateQueryWorker.terminationGracePeriodSeconds | int | `90` |  |
| replicaCount | int | `1` | Specify the number of lightdash instances. |
| resources | object | `{}` |  |
| scheduler.concurrency | int | `3` |  |
| scheduler.db.maxConnections | string | `nil` |  |
| scheduler.enabled | bool | `false` |  |
| scheduler.extraVolumeMounts | list | `[]` |  |
| scheduler.extraVolumes | list | `[]` |  |
| scheduler.livenessProbe.failureThreshold | int | `20` |  |
| scheduler.livenessProbe.initialDelaySeconds | int | `5` |  |
| scheduler.livenessProbe.periodSeconds | int | `15` |  |
| scheduler.livenessProbe.timeoutSeconds | int | `15` |  |
| scheduler.port | int | `8080` |  |
| scheduler.readinessProbe.failureThreshold | int | `2` |  |
| scheduler.readinessProbe.initialDelaySeconds | int | `5` |  |
| scheduler.readinessProbe.periodSeconds | int | `5` |  |
| scheduler.readinessProbe.timeoutSeconds | int | `5` |  |
| scheduler.replicas | int | `1` |  |
| scheduler.resources.requests.cpu | string | `"475m"` |  |
| scheduler.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| scheduler.resources.requests.memory | string | `"725Mi"` |  |
| scheduler.startupProbe.failureThreshold | int | `18` |  |
| scheduler.startupProbe.initialDelaySeconds | int | `5` |  |
| scheduler.startupProbe.periodSeconds | int | `10` |  |
| scheduler.startupProbe.timeoutSeconds | int | `10` |  |
| scheduler.tasks.exclude | string | `"runAsyncWarehouseQuery,runAsyncPreAggregateQuery"` |  |
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
| ssl.certFileName | string | `""` |  |
| ssl.configMapName | string | `""` |  |
| ssl.enabled | bool | `false` |  |
| ssl.mountPath | string | `"/etc/ssl/certs"` |  |
| tolerations | list | `[]` |  |
| warehouseQueryWorker.concurrency | int | `4` |  |
| warehouseQueryWorker.db.maxConnections | string | `nil` |  |
| warehouseQueryWorker.enabled | bool | `false` |  |
| warehouseQueryWorker.extraVolumeMounts | list | `[]` |  |
| warehouseQueryWorker.extraVolumes | list | `[]` |  |
| warehouseQueryWorker.livenessProbe.failureThreshold | int | `20` |  |
| warehouseQueryWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| warehouseQueryWorker.livenessProbe.periodSeconds | int | `15` |  |
| warehouseQueryWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| warehouseQueryWorker.pollInterval | string | `nil` |  |
| warehouseQueryWorker.port | int | `8080` |  |
| warehouseQueryWorker.readinessProbe.failureThreshold | int | `2` |  |
| warehouseQueryWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| warehouseQueryWorker.readinessProbe.periodSeconds | int | `5` |  |
| warehouseQueryWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| warehouseQueryWorker.replicas | int | `1` |  |
| warehouseQueryWorker.resources.requests.cpu | string | `"475m"` |  |
| warehouseQueryWorker.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| warehouseQueryWorker.resources.requests.memory | string | `"725Mi"` |  |
| warehouseQueryWorker.startupProbe.failureThreshold | int | `18` |  |
| warehouseQueryWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| warehouseQueryWorker.startupProbe.periodSeconds | int | `10` |  |
| warehouseQueryWorker.startupProbe.timeoutSeconds | int | `10` |  |
| warehouseQueryWorker.tasks.exclude | string | `nil` |  |
| warehouseQueryWorker.tasks.include | string | `"runAsyncWarehouseQuery"` |  |
| warehouseQueryWorker.terminationGracePeriodSeconds | int | `90` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.7.0](https://github.com/norwoodj/helm-docs/releases/v1.7.0)
