# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 2.5.0](https://img.shields.io/badge/Version-2.5.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.2248.0](https://img.shields.io/badge/AppVersion-0.2248.0-informational?style=flat-square)

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
| https://charts.bitnami.com/bitnami | postgresql | 11.x.x |
| https://charts.sagikazarmark.dev | browserless-chrome | 0.0.5 |
| https://nats-io.github.io/k8s/helm/charts/ | nats | 2.12.4 |

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
| nats.config.cluster.enabled | bool | `false` |  |
| nats.config.jetstream.enabled | bool | `true` |  |
| nats.config.jetstream.fileStore.enabled | bool | `false` |  |
| nats.config.jetstream.memoryStore.enabled | bool | `true` |  |
| nats.config.jetstream.memoryStore.maxSize | string | `"1Gi"` |  |
| nats.container.merge.resources.limits.memory | string | `"1Gi"` |  |
| nats.container.merge.resources.requests.cpu | string | `"100m"` |  |
| nats.container.merge.resources.requests.memory | string | `"256Mi"` |  |
| nats.enabled | bool | `false` |  |
| nats.monitor.enabled | bool | `true` |  |
| nats.monitor.port | int | `8222` |  |
| nats.nameOverride | string | `""` |  |
| nats.natsBox.enabled | bool | `false` |  |
| nats.networkPolicy.additionalIngress | list | `[]` |  |
| nats.networkPolicy.enabled | bool | `true` |  |
| nats.promExporter.enabled | bool | `false` |  |
| nats.promExporter.port | int | `7777` |  |
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
| preAggregateNatsWorker.command[0] | string | `"node"` |  |
| preAggregateNatsWorker.command[1] | string | `"dist/natsWorker.js"` |  |
| preAggregateNatsWorker.command[2] | string | `"--stream"` |  |
| preAggregateNatsWorker.command[3] | string | `"pre-aggregate"` |  |
| preAggregateNatsWorker.concurrency | int | `4` |  |
| preAggregateNatsWorker.db.maxConnections | string | `nil` |  |
| preAggregateNatsWorker.enabled | bool | `false` |  |
| preAggregateNatsWorker.extraVolumeMounts | list | `[]` |  |
| preAggregateNatsWorker.extraVolumes | list | `[]` |  |
| preAggregateNatsWorker.livenessProbe.failureThreshold | int | `20` |  |
| preAggregateNatsWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| preAggregateNatsWorker.livenessProbe.periodSeconds | int | `15` |  |
| preAggregateNatsWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| preAggregateNatsWorker.port | int | `8080` |  |
| preAggregateNatsWorker.readinessProbe.failureThreshold | int | `2` |  |
| preAggregateNatsWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| preAggregateNatsWorker.readinessProbe.periodSeconds | int | `5` |  |
| preAggregateNatsWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| preAggregateNatsWorker.replicas | int | `1` |  |
| preAggregateNatsWorker.resources.requests.cpu | string | `"475m"` |  |
| preAggregateNatsWorker.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| preAggregateNatsWorker.resources.requests.memory | string | `"725Mi"` |  |
| preAggregateNatsWorker.startupProbe.failureThreshold | int | `18` |  |
| preAggregateNatsWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| preAggregateNatsWorker.startupProbe.periodSeconds | int | `10` |  |
| preAggregateNatsWorker.startupProbe.timeoutSeconds | int | `10` |  |
| preAggregateNatsWorker.terminationGracePeriodSeconds | int | `90` |  |
| preAggregateNatsWorker.type | string | `"nats"` |  |
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
| scheduler.tasks.exclude | string | `nil` |  |
| scheduler.tasks.include | string | `nil` |  |
| scheduler.terminationGracePeriodSeconds | int | `90` |  |
| scheduler.type | string | `"graphile"` |  |
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
| warehouseNatsWorker.command[0] | string | `"node"` |  |
| warehouseNatsWorker.command[1] | string | `"dist/natsWorker.js"` |  |
| warehouseNatsWorker.command[2] | string | `"--stream"` |  |
| warehouseNatsWorker.command[3] | string | `"warehouse"` |  |
| warehouseNatsWorker.concurrency | int | `4` |  |
| warehouseNatsWorker.db.maxConnections | string | `nil` |  |
| warehouseNatsWorker.enabled | bool | `false` |  |
| warehouseNatsWorker.extraVolumeMounts | list | `[]` |  |
| warehouseNatsWorker.extraVolumes | list | `[]` |  |
| warehouseNatsWorker.livenessProbe.failureThreshold | int | `20` |  |
| warehouseNatsWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| warehouseNatsWorker.livenessProbe.periodSeconds | int | `15` |  |
| warehouseNatsWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| warehouseNatsWorker.port | int | `8080` |  |
| warehouseNatsWorker.readinessProbe.failureThreshold | int | `2` |  |
| warehouseNatsWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| warehouseNatsWorker.readinessProbe.periodSeconds | int | `5` |  |
| warehouseNatsWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| warehouseNatsWorker.replicas | int | `1` |  |
| warehouseNatsWorker.resources.requests.cpu | string | `"475m"` |  |
| warehouseNatsWorker.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| warehouseNatsWorker.resources.requests.memory | string | `"725Mi"` |  |
| warehouseNatsWorker.startupProbe.failureThreshold | int | `18` |  |
| warehouseNatsWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| warehouseNatsWorker.startupProbe.periodSeconds | int | `10` |  |
| warehouseNatsWorker.startupProbe.timeoutSeconds | int | `10` |  |
| warehouseNatsWorker.terminationGracePeriodSeconds | int | `90` |  |
| warehouseNatsWorker.type | string | `"nats"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.7.0](https://github.com/norwoodj/helm-docs/releases/v1.7.0)
