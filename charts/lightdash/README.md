# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 2.16.361](https://img.shields.io/badge/Version-2.16.361-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2.130.0](https://img.shields.io/badge/AppVersion-2.130.0-informational?style=flat-square)

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

### Externally managed secrets (Vault, External Secrets Operator)

#### How this chart handles secrets

A Kubernetes Secret is a named bundle of key/value pairs living in one namespace. It is base64-encoded, not encrypted, and a pod can only reference a Secret in its own namespace. Containers receive it as environment variables in one of two ways, and this chart uses both on purpose:

- **`env` with a `secretKeyRef`** — "create one variable named `X`, taking its value from key `Y` of Secret `Z`". Surgical: nothing else in that Secret reaches the container. The database password and the two S3 credentials are delivered this way.
- **`envFrom` with a `secretRef`** — "turn **every** key in Secret `Z` into a variable of the same name". Bulk: the Secret's key names *are* the variable names. The application Secret is delivered this way, because Lightdash reads dozens of optional settings and the chart cannot know which ones you use.

By default the chart **creates** Secrets for you out of plaintext values (`secrets`, `s3.accessKey`, `externalDatabase.password`), which means those values have to live in a values file. Setting `secretRefs.enabled: true` turns on **strict mode**: the chart creates no Secrets at all and renders only *references* to Secrets that already exist — normally produced by a controller that syncs them out of Vault.

Three things follow from that, and they are the crux of the whole feature:

1. **You create the Secrets, before you install the chart.**
2. **The chart validates names, never contents.** `helm install` succeeding proves the *names* line up. It proves nothing about the keys inside. A missing or misspelled key surfaces when a pod starts, as `CreateContainerConfigError`, not as a Helm error.
3. **Your values file contains no secrets.** That is the point.

#### Choosing a mechanism

| Mechanism | What it puts in the cluster | Support in this chart |
|---|---|---|
| **Vault Secrets Operator (VSO)** or **External Secrets Operator (ESO)** — a controller reconciles a custom resource into a Kubernetes Secret | A real Secret, kept in sync with Vault | Fully supported by `secretRefs`. **Recommended.** |
| **Per-key mapping through `extraEnv`** — you write `valueFrom.secretKeyRef` entries yourself | Nothing; references keys of a Secret you already have | Supported today on the backend, the workers (`schedulerExtraEnv`) and the migration Job (`migrationJob.extraEnv`) |
| **Vault Agent Injector** — `vault.hashicorp.com/*` pod annotations, a sidecar renders secrets to files | Files under `/vault/secrets`; no Kubernetes Secret | Partial. See [Vault Agent Injector](#vault-agent-injector) for what does and does not work |

Worked example values files live in [`examples/`](examples/): [`values-vault-vso.yaml`](examples/values-vault-vso.yaml) for the recommended operator setup, and [`values-vault-injector.yaml`](examples/values-vault-injector.yaml) for the injector hybrid.

#### Strict mode: `secretRefs`

```yaml
secretRefs:
  enabled: true
  application:
    name: lightdash-application
  database:
    name: lightdash-database
    passwordKey: PGPASSWORD
  s3:
    name: lightdash-s3
    accessKey: S3_ACCESS_KEY
    secretKey: S3_SECRET_KEY
  migration:
    name: lightdash-application # required when migrationJob.enabled=true
```

`accessKey`, `secretKey` and `passwordKey` name the key **inside your Secret**. The resulting environment variable names (`S3_ACCESS_KEY`, `S3_SECRET_KEY`, `PGPASSWORD`) are fixed by the chart.

#### What each workload receives

| Workload | Secret-backed `env` | `envFrom` |
|---|---|---|
| backend Deployment | `PGPASSWORD`, plus `S3_ACCESS_KEY` and `S3_SECRET_KEY` when `secretRefs.s3.name` is set | application ConfigMap, then `secretRefs.application.name` |
| all four worker Deployments | same as the backend | same as the backend |
| migration Job (Helm hook) | `PGPASSWORD` only — **never any S3 credential** | migration ConfigMap, then `secretRefs.migration.name` |

`postgresql.enabled: true` (the default) keeps the bundled database's own credential lifecycle and **ignores `secretRefs.database` entirely**; `PGPASSWORD` resolves to the subchart's Secret. To put the bundled password in Vault, use `postgresql.auth.existingSecret` instead.

#### Which keys each Secret must contain

| Secret | Key | Required? |
|---|---|---|
| `secretRefs.application.name` | `LIGHTDASH_SECRET` | **Yes.** Lightdash refuses to start without it |
| | anything you previously put in `secrets` or `existingSecret`, e.g. `LIGHTDASH_LICENSE_KEY` | carry it over |
| `secretRefs.database.name` | the key named by `passwordKey` (default `PGPASSWORD`) | **Yes**, when `postgresql.enabled: false`. This is the only key read |
| `secretRefs.s3.name` | the keys named by `accessKey` and `secretKey` | only if you use the Secret at all — omit the whole block for workload identity |
| `secretRefs.migration.name` | `LIGHTDASH_SECRET` | **Yes**, when `migrationJob.enabled: true`. See below |

Because the application and migration Secrets are injected with `envFrom`, **their keys must be spelled exactly as Lightdash expects** — `LIGHTDASH_SECRET`, not `lightdash_secret`. A mis-keyed payload does not fail the deploy; it produces an environment variable Lightdash never reads. Rename keys on the operator side (see [Renaming Vault keys](#renaming-vault-keys)).

`PGHOST`, `PGPORT`, `PGUSER` and `PGDATABASE` are **not** read from any Secret — they come from `externalDatabase.*` through a ConfigMap. Putting them in the Vault payload has no effect.

#### Why the migration Job needs `LIGHTDASH_SECRET`

The chart deliberately gives the migration Job less than the backend: the database password and its own Secret, never the application or S3 Secret. Lightdash disagrees. The migration entrypoint imports the same config module the web server uses, and that module validates on import — before any migration runs. It requires `LIGHTDASH_SECRET`, `S3_ENDPOINT`, `S3_BUCKET` and `S3_REGION` unconditionally, even though the migrator uses none of them.

So, with `migrationJob.enabled: true`:

- `secretRefs.migration.name` is **required**. The chart fails the render if it is unset while `migrationJob.extraEnv` is also empty; if you set `migrationJob.extraEnv` the chart assumes you are supplying `LIGHTDASH_SECRET` that way and stops checking. Pointing it at the same Secret as `secretRefs.application.name` is the simplest correct answer, and keeps a single source of truth — `LIGHTDASH_SECRET` encrypts stored warehouse credentials, so two copies that drift apart corrupt data rather than merely misconfigure.
- Set `s3.endpoint`, `s3.bucket` and `s3.region` rather than putting them in a Secret. Those are not secrets, and they flow into *both* ConfigMaps, so the backend and the migration Job are configured in one place.

#### Vault Secrets Operator

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: lightdash-application
  # Must be the release namespace: VSO writes the Secret into its own namespace,
  # and a pod can only read Secrets in its own namespace.
  namespace: lightdash
spec:
  vaultAuthRef: lightdash
  mount: kvv2
  type: kv-v2
  path: applications/lightdash/application
  refreshAfter: 60s
  destination:
    create: true
    name: lightdash-application
    # Add `overwrite: true` when adopting a Secret this chart previously created.
    transformation:
      # Required. Without it VSO adds a `_raw` key holding the entire Vault
      # response, and because this chart injects the application Secret with
      # envFrom, `_raw` becomes an environment variable containing that payload.
      excludeRaw: true
  # Kubernetes never updates environment variables in a running container, so a
  # rotation reaches nothing until the pods restart. List every Deployment you
  # have enabled. Leave `hmacSecretData` at its default: setting it to false
  # silently disables every target below.
  rolloutRestartTargets:
    - kind: Deployment
      name: RELEASE-lightdash-backend
    - kind: Deployment
      name: RELEASE-lightdash-worker
    - kind: Deployment
      name: RELEASE-lightdash-app-build-worker
    - kind: Deployment
      name: RELEASE-lightdash-pre-aggregate-nats-worker
    - kind: Deployment
      name: RELEASE-lightdash-warehouse-nats-worker
```

Create equivalent resources for the database and S3 destinations. `spec.namespace`, if you ever need it, is the Vault Enterprise namespace — not the Kubernetes one.

#### External Secrets Operator

```yaml
apiVersion: external-secrets.io/v1 # v1beta1 is not served from ESO v0.17.0
kind: ExternalSecret
metadata:
  name: lightdash-application
  namespace: lightdash
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: vault-backend
  target:
    name: lightdash-application # ESO's equivalent of VSO's destination.name
    creationPolicy: Owner
  data:
    # Explicit per-key mapping: secretKey is the environment variable name,
    # remoteRef.property is the key in Vault.
    - secretKey: LIGHTDASH_SECRET
      remoteRef:
        key: applications/lightdash/application
        property: lightdash_secret
```

ESO adds no `_raw` key and cannot restart workloads itself. Use a reloader controller or trigger `kubectl rollout restart` from your deployment system.

#### Renaming Vault keys

If your Vault payload uses different key names, rename them on the operator side rather than in the chart:

- **ESO** — `spec.data[].secretKey` (the name you want) with `remoteRef.property` (the Vault key), as above.
- **VSO** — `spec.destination.transformation.templates`, optionally with `excludes: [".*"]` to drop the originals:
  ```yaml
  transformation:
    excludeRaw: true
    excludes: [".*"]
    templates:
      LIGHTDASH_SECRET:
        text: '{{ get .Secrets "lightdash_secret" }}'
  ```
- **In the chart** — `extraEnv` (backend and workers), `schedulerExtraEnv` (workers) and `migrationJob.extraEnv` (migration Job) all accept arbitrary `valueFrom.secretKeyRef` entries and are appended last, so they also override anything delivered by `envFrom`:
  ```yaml
  extraEnv:
    - name: LIGHTDASH_SECRET
      valueFrom:
        secretKeyRef:
          name: lightdash-application
          key: lightdash_secret
  ```

#### Vault Agent Injector

The injector is driven by `vault.hashicorp.com/*` pod annotations and renders secrets into files under `/vault/secrets`. It creates no Kubernetes Secret. Put the annotations in `podAnnotations` (backend and all workers) or `migrationJob.podAnnotations`. `podAnnotations` is deliberately **not** processed with `tpl`, so Vault Agent templates pass through untouched.

Because Lightdash reads its configuration from the environment and Kubernetes cannot load an environment variable from a file, the only way to use injected files is to wrap the container command so it sources them:

```yaml
podAnnotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: lightdash
  vault.hashicorp.com/agent-inject-secret-env: kv/data/lightdash/app
  vault.hashicorp.com/agent-inject-perms-env: "0400" # default is 0644
  vault.hashicorp.com/agent-inject-template-env: |
    {{- with secret "kv/data/lightdash/app" -}}
    {{- range $k, $v := .Data.data }}
    export {{ $k }}='{{ $v | replaceAll "'" "'\\''" }}'
    {{- end }}
    {{- end }}

image:
  command: ["/bin/sh", "-c", "source /vault/secrets/env && exec dumb-init -- node dist/index.js"]
```

Each worker takes the same wrapper through its own `command`. Use single quotes with that `replaceAll` escaping rather than the double-quoted form in HashiCorp's own example: inside double quotes a value containing `$(...)` would execute at container start.

Known limits, all of which need a chart change to lift:

- **`PGPASSWORD` is always a `secretKeyRef`.** Every workload reads it from a Secret, unconditionally. A deployment with *no* Kubernetes Secret at all is therefore not possible today — pair the injector with one operator-managed Secret for the database password.
- **The migration Job's command is hardcoded**, so it cannot source an injected file. Give it `migrationJob.extraEnv` `secretKeyRef` entries, or a `secretRefs.migration.name` Secret, instead.
- **`podAnnotations` is shared** by the backend and all four workers, and they share one ServiceAccount, so all five must use the same Vault role.
- **On a Job, set `vault.hashicorp.com/agent-pre-populate-only: "true"`** if you ever annotate `migrationJob.podAnnotations`. Otherwise the Vault Agent sidecar never exits, the Job never completes, and the pre-install hook blocks the release until it times out.

The honest trade-off: the injector's advantage is that secrets stay in a tmpfs file and never become a Kubernetes Secret. The moment you `source` them into the environment, they are readable through `/proc/<pid>/environ` again — you have moved the exposure, not removed it.

#### Caveats

- **Create the Secrets before installing.** The migration Job is a `pre-install`/`pre-upgrade` hook, so it runs *before* Helm applies the rest of the chart. Operator resources supplied through `extraObjects` are applied too late, and Helm never waits for a controller to reconcile a custom resource. Confirm with `kubectl get secret` first.
- **Rotation does not restart anything.** In strict mode the chart's `checksum/secrets` pod annotation is the hash of an empty file and never changes, so `helm upgrade` will not roll pods either. Use `rolloutRestartTargets`, a reloader, or an explicit rollout.
- **Reusing an existing external-database Secret needs `secretRefs.database.passwordKey`.** Strict mode ignores `externalDatabase.secretKeys.passwordKey` (default `postgresql-password`) and uses `secretRefs.database.passwordKey` (default `PGPASSWORD`). If the key names disagree, the migration Job fails first and blocks the upgrade.
- **The S3 configuration check is inert in strict mode.** `S3_ENDPOINT`, `S3_BUCKET` and `S3_REGION` may legitimately arrive inside the application Secret, which the chart cannot read, so it stops validating them at render time. A typo produces a green `helm install` and a crash-looping backend.
- **Forgetting `enabled: true` fails silently.** The rest of the `secretRefs` block is ignored, and the chart falls back to creating a Secret containing `LIGHTDASH_SECRET: changeme`. Check with `kubectl get deploy <release>-lightdash-backend -o yaml | grep -A2 secretRef`.
- **A leftover `<release>-lightdash-externaldb` Secret** holding the old plaintext password survives the switch to strict mode; nothing references it, and nothing deletes it. Remove it manually.
- **`extraEnv` wins over everything.** It is appended last, so an entry named `S3_ACCESS_KEY` overrides the one from `secretRefs.s3` and shows up as a duplicate in `kubectl describe`.
- **Do not disable a block by nulling it.** `secretRefs: null` aborts the render with a nil-pointer error; use `enabled: false`.

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

## Database migrations during upgrades

Set one release-wide Deployment strategy when an external upgrade check decides whether an application version can roll safely:

```yaml
upgrade:
  mode: Recreate
migrationJob:
  enabled: true
```

Map a `true` upgrade-check result to `upgrade.mode: RollingUpdate`. Map `false` or an unknown result to `upgrade.mode: Recreate`. The chart does not call the upgrade-check service or fetch its verdict.

An explicit mode is authoritative for the backend and all four worker Deployments. `Recreate` removes any per-component `rollingUpdate` block. `RollingUpdate` keeps valid per-component `rollingUpdate` tuning. Leave `upgrade.mode` empty to preserve every existing per-component strategy exactly.

When `migrationJob.enabled` is `true`, a Helm upgrade automatically runs the scale-down sequence if the explicit mode is `Recreate`. For backward compatibility, an empty mode also runs it when the backend or any enabled worker has `strategy.type: Recreate`. It never scales workloads down during installation.

Before an upgrade migration that requires `Recreate`, the Job removes the backend HPA, scales the backend and every worker Deployment to zero, and waits for all matching application pods to terminate. The migration starts only after that wait succeeds. The migration Job pod is not part of the wait selector.

A successful upgrade applies the normal release manifests after the hook. Those manifests restore configured worker replicas and either `replicaCount` or `autoscaling.minReplicas` for the backend, then recreate the backend HPA when autoscaling is enabled. Application downtime lasts from the scale-down until the new pods become ready.

If the migration, wait, or any Kubernetes command fails, the upgrade fails closed. The Job does not restore the HPA or replicas, so the application remains stopped until an operator fixes the problem and retries or rolls back the release.

By default, the chart creates temporary namespace-scoped Role and RoleBinding hooks before a pre-upgrade scale-down. Set `migrationJob.scaleDownWorkloads.rbac.create: false` only when the migration service account can get and delete the named backend HPA, list Deployments, patch the scale subresource for the five named Lightdash Deployments, and get, list, and watch pods. The image, timeout, resources, and RBAC settings remain under `migrationJob.scaleDownWorkloads`. When `migrationJob.serviceAccount.create` is `false`, the named custom service account must exist before the migration hook starts. When it is `true`, the chart creates the migration service account as an earlier hook.

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
| existingSecret | string | `""` | Name of an existing Kubernetes secret to inject into all pods except the migration Job unless migrationJob.inheritGlobalEnv is true. Takes precedence over .Values.secrets when set. Ignored when secretRefs.enabled is true; use secretRefs.application.name instead. |
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
| image.args | list | `[]` | Extra container args, applied to the backend AND every worker. Prefer putting a full command in image.command or in the per-worker `command`, since there is no way to give the backend args without also giving them to the workers. |
| image.command | list | `[]` | Override the backend container command. A list, for example ["/bin/sh", "-c", "..."]. Leave empty to use the image default, or the no-migrate command when migrationJob.enabled is true. Workers ignore this; each worker block has its own `command`. |
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
| migrationJob.existingSecret | string | `""` | Name of an existing Kubernetes secret to inject into the migration Job. Ignored when secretRefs.enabled is true; use secretRefs.migration.name instead. |
| migrationJob.extraEnv | list | `[]` |  |
| migrationJob.extraVolumeMounts | list | `[]` |  |
| migrationJob.extraVolumes | list | `[]` |  |
| migrationJob.inheritGlobalEnv | bool | `false` | When true, the migration Job also receives the top-level extraEnv and existingSecret, so env supplied globally (for example LIGHTDASH_LICENSE_KEY) reaches the migrator. Default false keeps current behaviour. When secretRefs.enabled is true only the extraEnv half applies; existingSecret is ignored. |
| migrationJob.podAnnotations | object | `{}` |  |
| migrationJob.resources | object | `{}` |  |
| migrationJob.scaleDownWorkloads.image.pullPolicy | string | `"IfNotPresent"` |  |
| migrationJob.scaleDownWorkloads.image.repository | string | `"registry.k8s.io/kubectl"` |  |
| migrationJob.scaleDownWorkloads.image.tag | string | `"v1.33.4"` |  |
| migrationJob.scaleDownWorkloads.rbac.create | bool | `true` |  |
| migrationJob.scaleDownWorkloads.resources | object | `{}` |  |
| migrationJob.scaleDownWorkloads.timeoutSeconds | int | `300` |  |
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
| podAnnotations | object | `{}` | Annotations applied to the backend pod template AND to every worker pod template. Not processed with `tpl`, so Helm expressions are emitted verbatim (this is what makes Vault Agent Injector templates safe to put here). The migration Job has its own migrationJob.podAnnotations. |
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
| secretRefs | object | `{"application":{"name":""},"database":{"name":"","passwordKey":"PGPASSWORD"},"enabled":false,"migration":{"name":""},"s3":{"accessKey":"S3_ACCESS_KEY","name":"","secretKey":"S3_SECRET_KEY"}}` | Strict least-privilege references to Secrets managed outside this chart, for example by HashiCorp Vault Secrets Operator or External Secrets Operator. When enabled, legacy application, external-database, S3, and migration Secret values are ignored and the chart does not create those Secrets. The chart cannot read the contents of a Secret it does not create, so it validates names only: a missing or misspelled KEY surfaces when the pod starts, not at install time. |
| secretRefs.application.name | string | `""` | Secret containing application environment variables for the backend and workers. Injected in full with envFrom, so every key becomes an environment variable of the same name and must be spelled exactly as Lightdash expects it. Must contain LIGHTDASH_SECRET. Required when secretRefs.enabled is true. |
| secretRefs.database.name | string | `""` | Secret containing the external PostgreSQL password. Required with strict mode and postgresql.enabled=false; ignored for bundled PostgreSQL. |
| secretRefs.database.passwordKey | string | `"PGPASSWORD"` | Key inside secretRefs.database.name that holds the password. externalDatabase.secretKeys.passwordKey is IGNORED in strict mode, so when reusing a Secret you previously pointed externalDatabase.existingSecret at, set this to the key that Secret actually contains (often `postgresql-password`). |
| secretRefs.enabled | bool | `false` | Enable strict per-purpose externally managed Secret references |
| secretRefs.migration.name | string | `""` | Secret containing environment variables for the migration Job, injected in full with envFrom. Required when secretRefs.enabled and migrationJob.enabled are both true, because Lightdash reads LIGHTDASH_SECRET while loading its config and the Job receives neither the application nor the S3 Secret. Pointing this at the same Secret as secretRefs.application.name is fine. |
| secretRefs.s3.accessKey | string | `"S3_ACCESS_KEY"` | Key containing the S3 access key |
| secretRefs.s3.name | string | `""` | Secret containing S3 credentials for the backend and workers. Read with secretKeyRef, so only the two keys below are exposed. Leave empty when using workload identity or another ambient credential provider. Never mounted on the migration Job. |
| secretRefs.s3.secretKey | string | `"S3_SECRET_KEY"` | Key containing the S3 secret key |
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
| upgrade.mode | string | `""` |  |
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
