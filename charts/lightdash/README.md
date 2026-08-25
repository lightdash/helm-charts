# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 2.16.138](https://img.shields.io/badge/Version-2.16.138-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.255.0](https://img.shields.io/badge/AppVersion-1.255.0-informational?style=flat-square)

## Prerequisites

### Backend Database

#### PostgreSQL with Vector Extension Support

**Important**: Lightdash now requires PostgreSQL with the `vector` extension for embedding and advanced search functionality. This chart automatically uses the `pgvector/pgvector` Docker image which includes the required extension.

#### Using External PostgreSQL

If you want to use your own PostgreSQL instance, ensure it has the vector extension available!

#### Using the Bitnami PostgreSQL chart

You may wish to use the Bitnami PostgreSQL chart to spin up a development environment. This guidance is for convenience, you'll want to [read the docs](https://github.com/bitnami/charts/tree/master/bitnami/postgresql/#installing-the-chart) before deciding how to implement PostgresSQL.

The bundled database is created during chart installation. Helm upgrades do not modify it. Apply changes to `postgresql.*` values manually. The full management migration is planned for the 3.0.0 chart major.

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

### S3-compatible storage

Lightdash requires S3-compatible storage. Set the endpoint, bucket, and region when you install the chart:

```yaml
s3:
  endpoint: https://s3.amazonaws.com
  bucket: lightdash
  region: us-east-1
```

Set `s3.accessKey` and `s3.secretKey` for development only. For production, create a Kubernetes Secret with `S3_ACCESS_KEY` and `S3_SECRET_KEY`, then set `s3.existingSecret` to its name.

### Backend probe paths

`/api/v1/health` checks database access, `/api/v1/livez` checks process liveness without the database, and `/api/v1/readyz` checks TTL-cached readiness and migration state. Unless `lightdashBackend.readinessProbe.path` is set explicitly, the backend readiness probe uses `/api/v1/readyz` for stable Lightdash versions 1.169.1 and later, including build metadata, and `/api/v1/health` for earlier, prerelease, or unrecognised versions. Before 1.169.1, a parked migration could remove working pods from service.

### Database migration startup budget

The backend image runs database migrations before it starts the HTTP server when `migrationJob.enabled` is `false`. The backend startup probe covers this full startup path.

The default startup probe budget is about 185 seconds:

```text
initialDelaySeconds + (periodSeconds * failureThreshold)
5 + (10 * 18) = 185 seconds
```

The migration follower wait budget defaults to 30 minutes through `MIGRATION_WAIT_TIMEOUT_MS`. This wait budget does not limit the time that the lease holder spends running a migration. Size the startup probe for the follower wait budget plus the longest expected migration.

For example, a 30-minute follower wait and a 20-minute migration need about 50 minutes. The following values provide about 50 minutes and 5 seconds:

```yaml
lightdashBackend:
  startupProbe:
    initialDelaySeconds: 5
    timeoutSeconds: 10
    periodSeconds: 10
    failureThreshold: 300
```

For long migrations, set `migrationJob.enabled=true`. The migration hook Job has no startup probe, and the backend pods start after the Job completes.

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

A Pod Disruption Budget is enabled by default. It permits one pod to be evicted during a voluntary disruption:

```yaml
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1
```

Set `minAvailable` to pin a minimum number of available pods instead. When both fields are set, `minAvailable` takes precedence and `maxUnavailable` is ignored. Both fields accept zero.

**Important:** With `replicaCount: 1`, the default permits the only pod to be evicted, so it does not prevent downtime.

## Values

Note The `secret.*` values are used to create [kubernetes secrets](https://kubernetes.io/docs/concepts/configuration/secret/).
If you don't want helm to manage this, you may wish to separately create a secret named `<release-name>-lightdash`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| appBuildWorker.concurrency | int | `10` |  |
| appBuildWorker.db.maxConnections | string | `nil` |  |
| appBuildWorker.enabled | bool | `false` |  |
| appBuildWorker.extraVolumeMounts | list | `[]` |  |
| appBuildWorker.extraVolumes | list | `[]` |  |
| appBuildWorker.lifecycle | object | `{}` |  |
| appBuildWorker.livenessProbe.failureThreshold | int | `20` |  |
| appBuildWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| appBuildWorker.livenessProbe.periodSeconds | int | `15` |  |
| appBuildWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| appBuildWorker.port | int | `8080` |  |
| appBuildWorker.readinessProbe.failureThreshold | int | `2` |  |
| appBuildWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| appBuildWorker.readinessProbe.path | string | `"/api/v1/health"` |  |
| appBuildWorker.readinessProbe.periodSeconds | int | `5` |  |
| appBuildWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| appBuildWorker.replicas | int | `1` |  |
| appBuildWorker.resources.requests.cpu | string | `"475m"` |  |
| appBuildWorker.resources.requests.ephemeral-storage | string | `"1Gi"` |  |
| appBuildWorker.resources.requests.memory | string | `"725Mi"` |  |
| appBuildWorker.startupProbe.failureThreshold | int | `18` |  |
| appBuildWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| appBuildWorker.startupProbe.periodSeconds | int | `10` |  |
| appBuildWorker.startupProbe.timeoutSeconds | int | `10` |  |
| appBuildWorker.strategy | object | `{}` |  |
| appBuildWorker.tasks.exclude | string | `nil` |  |
| appBuildWorker.tasks.include | string | `"appGeneratePipeline"` |  |
| appBuildWorker.terminationGracePeriodSeconds | int | `90` |  |
| appBuildWorker.type | string | `"graphile"` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `100` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| backendConfig.create | bool | `false` |  |
| browserless-chrome.enabled | bool | `true` |  |
| browserless-chrome.env.CONNECTION_TIMEOUT | string | `"180000"` |  |
| browserless-chrome.image.repository | string | `"ghcr.io/browserless/chromium"` |  |
| browserless-chrome.image.tag | string | `"v2.49.0"` |  |
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
| existingSecret | string | `""` | Name of an existing Kubernetes secret to inject into all pods except the migration Job unless migrationJob.inheritGlobalEnv is true. Takes precedence over .Values.secrets when set. |
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
| lightdashBackend.lifecycle.preStop.exec.command[0] | string | `"sh"` |  |
| lightdashBackend.lifecycle.preStop.exec.command[1] | string | `"-c"` |  |
| lightdashBackend.lifecycle.preStop.exec.command[2] | string | `"sleep 10"` |  |
| lightdashBackend.livenessProbe.failureThreshold | int | `6` |  |
| lightdashBackend.livenessProbe.initialDelaySeconds | int | `5` |  |
| lightdashBackend.livenessProbe.periodSeconds | int | `15` |  |
| lightdashBackend.livenessProbe.timeoutSeconds | int | `15` |  |
| lightdashBackend.readinessProbe.failureThreshold | int | `2` |  |
| lightdashBackend.readinessProbe.initialDelaySeconds | int | `5` |  |
| lightdashBackend.readinessProbe.path | string | `""` | Backend probe endpoint path. /api/v1/health checks database access, /api/v1/livez checks process liveness without the database, and /api/v1/readyz checks TTL-cached readiness and migration state. The default is /api/v1/readyz for stable Lightdash versions 1.169.1 and later, including build metadata, and /api/v1/health for earlier, prerelease, or unrecognised versions. Before 1.169.1, a parked migration could remove working pods from service. |
| lightdashBackend.readinessProbe.periodSeconds | int | `5` |  |
| lightdashBackend.readinessProbe.timeoutSeconds | int | `5` |  |
| lightdashBackend.startupProbe | object | `{"failureThreshold":18,"initialDelaySeconds":5,"periodSeconds":10,"timeoutSeconds":10}` | Backend startup probe. When migrationJob.enabled is false, size its approximate initialDelaySeconds + (periodSeconds * failureThreshold) budget to cover the 30-minute MIGRATION_WAIT_TIMEOUT_MS default plus the longest expected migration. Enable migrationJob.enabled to run migrations in a hook Job without a startup probe. |
| lightdashBackend.startupProbe.failureThreshold | int | `18` | Failed backend startup probes before Kubernetes restarts the container |
| lightdashBackend.startupProbe.initialDelaySeconds | int | `5` | Delay before the first backend startup probe |
| lightdashBackend.startupProbe.periodSeconds | int | `10` | Interval between backend startup probes |
| lightdashBackend.startupProbe.timeoutSeconds | int | `10` | Timeout for each backend startup probe |
| lightdashBackend.strategy | object | `{}` |  |
| lightdashBackend.terminationGracePeriodSeconds | int | `90` |  |
| migrationJob.affinity | object | `{}` |  |
| migrationJob.backoffLimit | int | `10` |  |
| migrationJob.enabled | bool | `false` |  |
| migrationJob.existingSecret | string | `""` |  |
| migrationJob.extraEnv | list | `[]` |  |
| migrationJob.extraVolumeMounts | list | `[]` |  |
| migrationJob.extraVolumes | list | `[]` |  |
| migrationJob.inheritGlobalEnv | bool | `false` | When true, the migration Job also receives the top-level extraEnv and existingSecret, so env supplied globally (for example LIGHTDASH_LICENSE_KEY) reaches the migrator. Default false keeps current behaviour. |
| migrationJob.podAnnotations | object | `{}` |  |
| migrationJob.resources | object | `{}` |  |
| migrationJob.serviceAccount.annotations | object | `{}` |  |
| migrationJob.serviceAccount.create | bool | `true` |  |
| migrationJob.serviceAccount.name | string | `""` |  |
| migrationJob.ssl.certFileName | string | `""` |  |
| migrationJob.ssl.configMapName | string | `""` |  |
| migrationJob.ssl.enabled | bool | `false` |  |
| migrationJob.ssl.mountPath | string | `"/etc/ssl/certs"` |  |
| migrationJob.tolerations | list | `[]` |  |
| migrationJob.ttlSecondsAfterFinished | int | `100` |  |
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
| nats.networkPolicy.nodeCIDRs | list | `[]` |  |
| nats.podDisruptionBudget.merge.spec.maxUnavailable | int | `0` |  |
| nats.promExporter.enabled | bool | `true` |  |
| nats.promExporter.merge.resources.requests.cpu | string | `"100m"` |  |
| nats.promExporter.merge.resources.requests.memory | string | `"128Mi"` |  |
| nats.promExporter.port | int | `7777` |  |
| nats.reloader.enabled | bool | `false` |  |
| nats.statefulSet.merge.spec.template.metadata.annotations."cluster-autoscaler.kubernetes.io/safe-to-evict" | string | `"false"` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podAntiAffinity.enabled | bool | `false` |  |
| podAntiAffinity.node | string | `"hard"` |  |
| podAntiAffinity.zone | string | `"soft"` |  |
| podDisruptionBudget.enabled | bool | `true` |  |
| podDisruptionBudget.maxUnavailable | int | `1` |  |
| podLabels | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| postgresql.auth.database | string | `"lightdash"` |  |
| postgresql.auth.existingSecret | string | `""` |  |
| postgresql.auth.password | string | `""` |  |
| postgresql.auth.secretKeys.userPasswordKey | string | `"password"` |  |
| postgresql.auth.username | string | `"lightdash"` |  |
| postgresql.commonAnnotations."helm.sh/hook" | string | `"pre-install"` |  |
| postgresql.commonAnnotations."helm.sh/hook-weight" | string | `"-1"` |  |
| postgresql.enabled | bool | `true` |  |
| postgresql.image.registry | string | `"docker.io"` |  |
| postgresql.image.repository | string | `"pgvector/pgvector"` |  |
| postgresql.image.tag | string | `"pg16"` |  |
| preAggregateNatsWorker.command[0] | string | `"node"` |  |
| preAggregateNatsWorker.command[1] | string | `"dist/natsWorker.js"` |  |
| preAggregateNatsWorker.command[2] | string | `"--stream"` |  |
| preAggregateNatsWorker.command[3] | string | `"pre-aggregate"` |  |
| preAggregateNatsWorker.concurrency | int | `100` |  |
| preAggregateNatsWorker.db.maxConnections | string | `nil` |  |
| preAggregateNatsWorker.enabled | bool | `false` |  |
| preAggregateNatsWorker.extraVolumeMounts | list | `[]` |  |
| preAggregateNatsWorker.extraVolumes | list | `[]` |  |
| preAggregateNatsWorker.lifecycle | object | `{}` |  |
| preAggregateNatsWorker.livenessProbe.failureThreshold | int | `20` |  |
| preAggregateNatsWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| preAggregateNatsWorker.livenessProbe.periodSeconds | int | `15` |  |
| preAggregateNatsWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| preAggregateNatsWorker.port | int | `8080` |  |
| preAggregateNatsWorker.readinessProbe.failureThreshold | int | `2` |  |
| preAggregateNatsWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| preAggregateNatsWorker.readinessProbe.path | string | `"/api/v1/health"` |  |
| preAggregateNatsWorker.readinessProbe.periodSeconds | int | `5` |  |
| preAggregateNatsWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| preAggregateNatsWorker.replicas | int | `1` |  |
| preAggregateNatsWorker.resources.requests.cpu | string | `"650m"` |  |
| preAggregateNatsWorker.resources.requests.ephemeral-storage | string | `"9Gi"` |  |
| preAggregateNatsWorker.resources.requests.memory | string | `"4Gi"` |  |
| preAggregateNatsWorker.startupProbe.failureThreshold | int | `18` |  |
| preAggregateNatsWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| preAggregateNatsWorker.startupProbe.periodSeconds | int | `10` |  |
| preAggregateNatsWorker.startupProbe.timeoutSeconds | int | `10` |  |
| preAggregateNatsWorker.strategy | object | `{}` |  |
| preAggregateNatsWorker.terminationGracePeriodSeconds | int | `90` |  |
| preAggregateNatsWorker.type | string | `"nats"` |  |
| replicaCount | int | `1` | Specify the number of lightdash instances. |
| resources | object | `{}` |  |
| s3.accessKey | string | `""` | Access key for S3-compatible storage. Prefer existingSecret for production credentials. |
| s3.bucket | string | `""` | S3-compatible storage bucket |
| s3.endpoint | string | `""` | S3-compatible storage endpoint, for example https://s3.amazonaws.com |
| s3.existingSecret | string | `""` | Name of an existing Kubernetes Secret containing S3_ACCESS_KEY and S3_SECRET_KEY |
| s3.forcePathStyle | string | `""` | Set to true when the S3-compatible storage service requires path-style URLs |
| s3.publicEndpoint | string | `""` | Public endpoint used to access objects stored in S3-compatible storage |
| s3.region | string | `""` | S3-compatible storage region |
| s3.secretKey | string | `""` | Secret key for S3-compatible storage. Prefer existingSecret for production credentials. |
| scheduler.concurrency | int | `3` |  |
| scheduler.db.maxConnections | string | `nil` |  |
| scheduler.enabled | bool | `false` |  |
| scheduler.extraVolumeMounts | list | `[]` |  |
| scheduler.extraVolumes | list | `[]` |  |
| scheduler.lifecycle | object | `{}` |  |
| scheduler.livenessProbe.failureThreshold | int | `20` |  |
| scheduler.livenessProbe.initialDelaySeconds | int | `5` |  |
| scheduler.livenessProbe.periodSeconds | int | `15` |  |
| scheduler.livenessProbe.timeoutSeconds | int | `15` |  |
| scheduler.port | int | `8080` |  |
| scheduler.readinessProbe.failureThreshold | int | `2` |  |
| scheduler.readinessProbe.initialDelaySeconds | int | `5` |  |
| scheduler.readinessProbe.path | string | `"/api/v1/health"` |  |
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
| scheduler.strategy | object | `{}` |  |
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
| warehouseNatsWorker.concurrency | int | `100` |  |
| warehouseNatsWorker.db.maxConnections | string | `nil` |  |
| warehouseNatsWorker.enabled | bool | `false` |  |
| warehouseNatsWorker.extraVolumeMounts | list | `[]` |  |
| warehouseNatsWorker.extraVolumes | list | `[]` |  |
| warehouseNatsWorker.lifecycle | object | `{}` |  |
| warehouseNatsWorker.livenessProbe.failureThreshold | int | `20` |  |
| warehouseNatsWorker.livenessProbe.initialDelaySeconds | int | `5` |  |
| warehouseNatsWorker.livenessProbe.periodSeconds | int | `15` |  |
| warehouseNatsWorker.livenessProbe.timeoutSeconds | int | `15` |  |
| warehouseNatsWorker.port | int | `8080` |  |
| warehouseNatsWorker.readinessProbe.failureThreshold | int | `2` |  |
| warehouseNatsWorker.readinessProbe.initialDelaySeconds | int | `5` |  |
| warehouseNatsWorker.readinessProbe.path | string | `"/api/v1/health"` |  |
| warehouseNatsWorker.readinessProbe.periodSeconds | int | `5` |  |
| warehouseNatsWorker.readinessProbe.timeoutSeconds | int | `5` |  |
| warehouseNatsWorker.replicas | int | `1` |  |
| warehouseNatsWorker.resources.requests.cpu | string | `"250m"` |  |
| warehouseNatsWorker.resources.requests.ephemeral-storage | string | `"9Gi"` |  |
| warehouseNatsWorker.resources.requests.memory | string | `"1.5Gi"` |  |
| warehouseNatsWorker.startupProbe.failureThreshold | int | `18` |  |
| warehouseNatsWorker.startupProbe.initialDelaySeconds | int | `5` |  |
| warehouseNatsWorker.startupProbe.periodSeconds | int | `10` |  |
| warehouseNatsWorker.startupProbe.timeoutSeconds | int | `10` |  |
| warehouseNatsWorker.strategy | object | `{}` |  |
| warehouseNatsWorker.terminationGracePeriodSeconds | int | `90` |  |
| warehouseNatsWorker.type | string | `"nats"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.7.0](https://github.com/norwoodj/helm-docs/releases/v1.7.0)
