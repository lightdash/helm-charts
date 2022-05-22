# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.27.1](https://img.shields.io/badge/AppVersion-0.27.1-informational?style=flat-square)

## Prerequisites

### Backend Database

#### Using the Bitnami PostgreSQL chart

Note, a persistent volume claim is created called `data-lightdashdb-postgresql-0` is created at invocation of the above. It is not deleted if `helm uninstall` is called.

Use `--set postgresql.primary.persistence.enabled=false` to skip creating a persistent volume claim(for development purposes only).

## Installing Lightdash

```
helm repo add lightdash https://lightdash.github.io/helm-charts
helm install lightdash ligthdash/lightdash

```

## Values

Note The `secret.*` values are used to create [kubernetes secrets](https://kubernetes.io/docs/concepts/configuration/secret/).
If you don't want helm to manage this, you may wish to separately create a secret named `<release-name>-lightdash`.

| Key                                        | Type   | Default                    | Description                                                                                                           |
| ------------------------------------------ | ------ | -------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| affinity                                   | object | `{}`                       |                                                                                                                       |
| autoscaling.enabled                        | bool   | `false`                    |                                                                                                                       |
| autoscaling.maxReplicas                    | int    | `100`                      |                                                                                                                       |
| autoscaling.minReplicas                    | int    | `1`                        |                                                                                                                       |
| autoscaling.targetCPUUtilizationPercentage | int    | `80`                       |                                                                                                                       |
| configMap.DBT_PROJECT_DIR                  | string | `""`                       | Path to your local dbt project. Only set this value if you are mounting a DBT project                                 |
| configMap.PORT                             | string | `"8080"`                   | Port for lightdash                                                                                                    |
| configMap.SECURE_COOKIES                   | string | `"false"`                  | Secure Cookies                                                                                                        |
| configMap.SITE_URL                         | string | `""`                       | Public URL of your instance including protocol e.g. https://lightdash.myorg.com                                       |
| configMap.TRUST_PROXY                      | string | `"false"`                  | Trust the reverse proxy when setting secure cookies (via the "X-Forwarded-Proto" header)                              |
| fullnameOverride                           | string | `""`                       |                                                                                                                       |
| image.pullPolicy                           | string | `"IfNotPresent"`           |                                                                                                                       |
| image.repository                           | string | `"lightdash/lightdash"`    |                                                                                                                       |
| image.tag                                  | string | `"0.27.1"`                 |                                                                                                                       |
| imagePullSecrets                           | list   | `[]`                       |                                                                                                                       |
| ingress.annotations                        | object | `{}`                       |                                                                                                                       |
| ingress.className                          | string | `""`                       |                                                                                                                       |
| ingress.enabled                            | bool   | `false`                    |                                                                                                                       |
| ingress.hosts[0].host                      | string | `"chart-example.local"`    |                                                                                                                       |
| ingress.hosts[0].paths[0].path             | string | `"/"`                      |                                                                                                                       |
| ingress.hosts[0].paths[0].pathType         | string | `"ImplementationSpecific"` |                                                                                                                       |
| ingress.tls                                | list   | `[]`                       |                                                                                                                       |
| nameOverride                               | string | `""`                       |                                                                                                                       |
| nodeSelector                               | object | `{}`                       |                                                                                                                       |
| podAnnotations                             | object | `{}`                       |                                                                                                                       |
| podSecurityContext                         | object | `{}`                       |                                                                                                                       |
| replicaCount                               | int    | `1`                        | Specify the number of lightdash instances.                                                                            |
| resources                                  | object | `{}`                       |                                                                                                                       |
| secrets.LIGHTDASH_SECRET                   | string | `"changeme"`               | This is the secret used to sign the session ID cookie and to encrypt sensitive information. Do not share this secret! |
| securityContext                            | object | `{}`                       |                                                                                                                       |
| service.port                               | int    | `80`                       |                                                                                                                       |
| service.type                               | string | `"ClusterIP"`              |                                                                                                                       |
| tolerations                                | list   | `[]`                       |                                                                                                                       |

### Lightdash Database parameters

| Name                                               | Description                                                                               | Value                                                           |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `postgresql.enabled`                               | Switch to enable or disable the PostgreSQL helm chart                                     | `true`                                                          |
| `postgresql.postgresqlUsername`                    | Lightdash Postgresql username                                                             | `lightdash`                                                     |
| `postgresql.postgresqlPassword`                    | Lightdash Postgresql password                                                             | `lightdash`                                                     |
| `postgresql.postgresqlDatabase`                    | Lightdash Postgresql database                                                             | `lightdash`                                                     |
| `postgresql.existingSecret`                        | Name of an existing secret containing the PostgreSQL password ('postgresql-password' key) | `""`                                                            |
| `postgresql.containerSecurityContext.runAsNonRoot` | Ensures the container will run with a non-root user                                       | `true`                                                          |
| `postgresql.commonAnnotations.helm.sh/hook`        | It will determine when the hook should be rendered                                        | `undefined`                                                     |
| `postgresql.commonAnnotations.helm.sh/hook-weight` | The order in which the hooks are executed. If weight is lower, it has higher priority     | `undefined`                                                     |
| `externalDatabase.host`                            | Database host                                                                             | `localhost or lightdashdb-postgresql.default.svc.cluster.local` |
| `externalDatabase.user`                            | non-root Username for Lightdash Database                                                  | `lightdash`                                                     |
| `externalDatabase.password`                        | Database password                                                                         | `""`                                                            |
| `externalDatabase.existingSecret`                  | Name of an existing secret resource containing the DB password                            | `""`                                                            |
| `externalDatabase.existingSecretPasswordKey`       | Name of an existing secret key containing the DB password                                 | `""`                                                            |
| `externalDatabase.database`                        | Database name                                                                             | `lightdash`                                                     |
| `externalDatabase.port`                            | Database port number                                                                      | `5432`                                                          |
