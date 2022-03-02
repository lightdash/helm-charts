# lightdash

A Helm chart to deploy lightdash on kubernetes

![Version: 0.3.0](https://img.shields.io/badge/Version-0.3.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.27.1](https://img.shields.io/badge/AppVersion-0.27.1-informational?style=flat-square)

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
helm install lightdash ligthdash/lightdash \
  --set configMap.PGHOST=lightdashdb-postgresql.default.svc.cluster.local \
  --set secrets.PGPASSWORD=changeme \

```

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
| databaseConfigMap.PGDATABASE | string | `"lightdash"` | Database name inside postgres server to store Lightdash data |
| databaseConfigMap.PGHOST | string | `"lightdashdb-postgresql.default.svc.cluster.local"` | Hostname of postgres server to store Lightdash data |
| databaseConfigMap.PGMAXCONNECTIONS | string | `"100"` | Maximum number of connections to postgres server |
| databaseConfigMap.PGMINCONNECTIONS | string | `"1"` | Minimum number of connections to postgres server |
| databaseConfigMap.PGPORT | string | `"5432"` | Port of postgres server to store Lightdash data |
| databaseSecrets.PGCONNECTIONURI | string | `""` | Connection URI for postgres server to store Lightdash data in the format postgresql://user:password@host:port/db?params |
| databaseSecrets.PGPASSWORD | string | `"changeme"` | Password for PGUSER |
| databaseSecrets.PGUSER | string | `"lightdash"` | Username of postgres user to access postgres server to store Lightdash data |
| emailConfigMap.EMAIL_SMTP_ALLOW_INVALID_CERT | string | `"false"` | Allow connection to TLS server with self-signed or invalid TLS certificate |
| emailConfigMap.EMAIL_SMTP_HOST | string | `""` | Hostname of email server. Empty string disables email. |
| emailConfigMap.EMAIL_SMTP_PORT | string | `"587"` | Port of email server |
| emailConfigMap.EMAIL_SMTP_SECURE | string | `"true"` | Secure connection |
| emailConfigMap.EMAIL_SMTP_SENDER_EMAIL | string | `""` | The email address that sends emails |
| emailConfigMap.EMAIL_SMTP_SENDER_NAME | string | `"Lightdash"` | The name of the email address that sends emails |
| emailSecrets.EMAIL_SMTP_ACCESS_TOKEN | string | `""` | Auth access token for Oauth2 authentication |
| emailSecrets.EMAIL_SMTP_PASSWORD | string | `""` | Auth password |
| emailSecrets.EMAIL_SMTP_USER | string | `""` | Auth user |
| fullnameOverride | string | `""` |  |
| image.args | list | `[]` |  |
| image.command | list | `[]` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"lightdash/lightdash"` |  |
| image.tag | string | `"0.27.1"` | Override the image tag |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.tls | list | `[]` |  |
| lightdashConfigMap.AUTH_DISABLE_PASSWORD_AUTHENTICATION | string | `"false"` | Prevent login with a password, essentially only permitting OpenID credentials. |
| lightdashConfigMap.DBT_PROJECT_DIR | string | `""` | Path to your local dbt project. Only set this value if you are mounting a DBT project |
| lightdashConfigMap.LIGHTDASH_CONFIG_FILE | string | `"/usr/app/lightdash.yml"` | Path to a lightdash.yml file to configure Lightdash. This is set by default and if you're using docker you shouldn't change it. |
| lightdashConfigMap.LIGHTDASH_INSTALL_ID | string | `""` | Unique install ID. Random UUID generated by default. |
| lightdashConfigMap.LIGHTDASH_INSTALL_TYPE | string | `"docker_image"` | One of `docker_image`, `bash_install`, `heroku`, `unknown` |
| lightdashConfigMap.LIGHTDASH_LOG_LEVEL | string | `""` | One of `error`, `warn`, `info`, `http`, `debug` |
| lightdashConfigMap.LIGHTDASH_MODE | string | `"default"` | One of `default`, `demo`, `pr`, `cloud_beta` |
| lightdashConfigMap.PORT | string | `"8080"` | Port for lightdash |
| lightdashConfigMap.SECURE_COOKIES | string | `"false"` | Only allows cookies to be stored over a https connection. We use cookies to keep you logged in. This is recommended to be set to true in production. |
| lightdashConfigMap.SITE_URL | string | `""` | Site url where Lightdash is being hosted. It should include the protocol. E.g https://lightdash.mycompany.com |
| lightdashConfigMap.TRUST_PROXY | string | `"false"` | This tells the Lightdash server that it can trust the X-Forwarded-Proto header it receives in requests. This is useful if you use SECURE_COOKIES=true behind a HTTPS terminated proxy that you can trust. |
| lightdashSecrets.AUTH_GOOGLE_OAUTH2_CLIENT_ID | string | `""` |  |
| lightdashSecrets.AUTH_GOOGLE_OAUTH2_CLIENT_SECRET | string | `""` |  |
| lightdashSecrets.CHATWOOT_BASE_URL | string | `""` |  |
| lightdashSecrets.CHATWOOT_TOKEN | string | `""` |  |
| lightdashSecrets.COHERE_TOKEN | string | `""` |  |
| lightdashSecrets.LIGHTDASH_SECRET | string | `"changeme"` | Secret key used to secure various tokens in Lightdash. This must be fixed between deployments. If the secret changes, you won't have access to Lightdash data. |
| lightdashSecrets.RUDDERSTACK_DATA_PLANE_URL | string | `""` |  |
| lightdashSecrets.RUDDERSTACK_WRITE_KEY | string | `""` |  |
| lightdashSecrets.SENTRY_DSN | string | `""` | Sentry Integration DSN |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| replicaCount | int | `1` | Specify the number of lightdash instances. |
| resources | object | `{}` |  |
| securityContext | object | `{}` |  |
| service.port | int | `80` |  |
| service.type | string | `"ClusterIP"` |  |
| tolerations | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.7.0](https://github.com/norwoodj/helm-docs/releases/v1.7.0)
