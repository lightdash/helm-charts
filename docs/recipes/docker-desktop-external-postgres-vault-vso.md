# Local Lightdash on Docker Desktop Kubernetes with an external PostgreSQL

This recipe deploys the Lightdash Helm chart from the current checkout into
Docker Desktop's built-in Kubernetes, against a PostgreSQL that the chart does
not manage, with every secret delivered from a local Vault by Vault Secrets
Operator (VSO).

> **Local learning only:** Vault runs in development mode over HTTP with an
> in-memory store and a known root token, and PostgreSQL keeps its data in an
> `emptyDir` that is lost when the pod restarts. Never use either in production.

## How this differs from the Kind recipe

[The Kind recipe](local-kind-vault-vso.md) uses the chart's bundled PostgreSQL.
This one turns that off and points the chart at a database it does not own,
which is how you would run against Cloud SQL, RDS, or a database another team
operates. That changes which parts of the chart are exercised:

| | Kind recipe | This recipe |
|---|---|---|
| Cluster | Kind, its own kubeconfig | Docker Desktop, shares your default kubeconfig |
| Database | bundled `postgresql` subchart | separate Deployment the chart does not manage |
| `postgresql.enabled` | `true` | `false` |
| `secretRefs.database` | ignored | **required**, supplies `PGPASSWORD` |
| Vault paths | one | two: application and database |

`secretRefs.database` only takes effect when `postgresql.enabled: false`, so it
is unreachable in the Kind recipe and is the main thing this one covers.

One deliberate simplification: the database runs inside the cluster, in the same
namespace, as an ordinary Deployment applied with `kubectl`. It is "external" in
the sense the chart means, namely that the chart neither creates nor owns it, so
credentials must be supplied rather than generated. Keeping it in one namespace
means a single Vault authentication config serves both the database server and
Lightdash, and both read the same password from the same Vault path.

## The tools this recipe uses

**Docker Desktop Kubernetes** runs a single-node cluster inside the same virtual
machine Docker already uses. Unlike Kind it needs no extra download, but it is a
singleton: there is one cluster, it is reset from the GUI rather than a command,
and it adds its context to your **default** kubeconfig alongside any real
clusters you have. Every command below therefore passes `--context
docker-desktop` explicitly.

**Vault** stores secrets, here in development mode inside the cluster.

**Vault Secrets Operator (VSO)** watches resources you create, reads the Vault
paths they name, and writes the results into ordinary Kubernetes Secrets. The
chart then references those Secrets through `secretRefs`, and so does the
PostgreSQL Deployment.

```text
Vault kv/lightdash/application  -> VSO -> Secret lightdash-application -> backend, workers
Vault kv/lightdash/database     -> VSO -> Secret lightdash-database    -> PostgreSQL server
                                                                       -> backend PGPASSWORD
```

Both the database server and its client take the same password from one Vault
path, so it exists in exactly one place.

## 1. Confirm the workspace and ignore rule

```bash
# Move to the top of the Git repository, wherever you cloned it.
cd "$(git rev-parse --show-toplevel)"

# Show which branch you are on. This recipe deploys whatever is checked out.
git branch --show-current

# Confirm Git ignores .context/, the scratch folder this recipe writes into.
git check-ignore -v .context/
```

## 2. Check Docker, the chip, and free space

```bash
# Check Docker is running, and see how much CPU and memory it may use.
docker info --format 'server={{.ServerVersion}} cpus={{.NCPU}} memory={{.MemTotal}}'

# Print the Mac's chip: arm64 is Apple Silicon, x86_64 is Intel.
uname -m

# How much of Docker's virtual disk is already in use.
docker system df
```

On Apple Silicon you need roughly 12 GB free, because the Lightdash image is
published for amd64 only and is about 10 GB. If `docker system df` shows little
headroom, `docker buildx prune -a` frees build cache at no cost beyond slower
future builds. Note that `docker builder prune` may not reach Docker if another
tool has aliased `builder` in `~/.docker/config.json`.

## 3. Enable the containerd image store

Do this **before** creating the cluster. Docker Desktop's Kubernetes has its own
image store, so by default an image you pull with `docker pull` is invisible to
it. With the containerd image store enabled the two share images, which is what
lets you side-load the amd64 Lightdash image in step 12.

In Docker Desktop: **Settings, General, Use containerd for pulling and storing
images**. Apply and restart. Then confirm:

```bash
# Should report io.containerd.snapshotter.v1 rather than overlay2.
docker info --format 'driver={{.Driver}}'
```

Enabling this hides images stored under the old driver until you switch back.
They are not deleted.

## 4. Create the Kubernetes cluster

In Docker Desktop: **Settings, Kubernetes, Enable Kubernetes**, choose a
single-node cluster, and apply. Then:

```bash
# A docker-desktop context is added to your DEFAULT kubeconfig. This recipe
# never changes your current context; it names the context on every command.
kubectl config get-contexts

# One node, and it should be Ready.
kubectl --context docker-desktop get nodes
```

If you also have production clusters in this kubeconfig, keep using
`--context docker-desktop` rather than `kubectl config use-context`, so an
unqualified `kubectl` in another terminal cannot reach this lab by accident.

## 5. Create the local directory structure

```bash
# Somewhere for the Helm binary and this lab's isolated Helm state.
mkdir -p .context/dd-external/bin
mkdir -p .context/dd-external/helm/config
mkdir -p .context/dd-external/helm/cache
mkdir -p .context/dd-external/helm/data
```

## 6. Download and verify Helm 3

```bash
# 3.21.4 is the version this repository's CI uses.
helm_version='v3.21.4'
helm_platform='darwin-arm64'   # Intel Mac: change to darwin-amd64
helm_archive="$PWD/.context/dd-external/helm-${helm_version}-${helm_platform}.tar.gz"
helm_checksum_file="${helm_archive}.sha256sum"

# Download the Helm archive and its published fingerprint.
curl -fsSL "https://get.helm.sh/helm-${helm_version}-${helm_platform}.tar.gz" \
  -o "$helm_archive"
curl -fsSL "https://get.helm.sh/helm-${helm_version}-${helm_platform}.tar.gz.sha256sum" \
  -o "$helm_checksum_file"

# Verify before unpacking. `test` prints nothing on success and fails otherwise.
helm_expected_checksum="$(awk '{print $1}' "$helm_checksum_file")"
helm_actual_checksum="$(shasum -a 256 "$helm_archive" | awk '{print $1}')"
test "$helm_actual_checksum" = "$helm_expected_checksum"

# Unpack and confirm the version.
tar -xzf "$helm_archive" -C .context/dd-external
cp .context/dd-external/darwin-arm64/helm .context/dd-external/bin/helm
chmod +x .context/dd-external/bin/helm
.context/dd-external/bin/helm version --short
```

## 7. Configure isolated Helm state

```bash
# Send Helm's settings, cache, and plugins into .context/ rather than your home
# folder, so this lab cannot alter your existing Helm setup.
export HELM_CONFIG_HOME="$PWD/.context/dd-external/helm/config"
export HELM_CACHE_HOME="$PWD/.context/dd-external/helm/cache"
export HELM_DATA_HOME="$PWD/.context/dd-external/helm/data"

# Shorthand for the Helm 3 binary downloaded above.
helm_local="$PWD/.context/dd-external/bin/helm"

# Register HashiCorp's chart repository and download its catalogue.
"$helm_local" repo add hashicorp https://helm.releases.hashicorp.com --force-update
"$helm_local" repo update
```

That isolation comes from the exported variables, so run the remaining steps in
this same shell, or re-export all four lines in a new one.

## 8. Install Vault and store both secrets

```bash
# Install Vault in development mode: in-memory storage, unseals itself, root
# token "root". injector.enabled=false because this lab uses VSO instead.
"$helm_local" --kube-context docker-desktop upgrade --install vault hashicorp/vault \
  --version 0.34.1 \
  --namespace vault \
  --create-namespace \
  --set server.dev.enabled=true \
  --set injector.enabled=false \
  --wait \
  --timeout 5m

# Helm's --wait does not cover this pod: the Vault chart sets the StatefulSet's
# updateStrategy to OnDelete, and Helm 3 treats any StatefulSet that is not
# RollingUpdate as instantly ready. Without this wait the next command fails with
# "container not found".
kubectl --context docker-desktop -n vault wait \
  --for=condition=Ready pod/vault-0 --timeout=180s

# Expect Initialized true and Sealed false.
kubectl --context docker-desktop -n vault exec vault-0 -- \
  env VAULT_TOKEN=root vault status
```

Now create the two secrets:

```bash
# Turn on a key-value store, version 2, at the path kv/.
kubectl --context docker-desktop -n vault exec vault-0 -- \
  env VAULT_TOKEN=root vault secrets enable -path=kv kv-v2

# Generate both secrets locally so they never appear in a file.
lightdash_secret="$(openssl rand -hex 32)"
database_password="$(openssl rand -hex 24)"

# Application secrets, read by the backend and workers.
kubectl --context docker-desktop -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv put kv/lightdash/application \
  "LIGHTDASH_SECRET=$lightdash_secret" \
  "VSO_DEMO_VERSION=one"

# The database password, read by BOTH the PostgreSQL server and Lightdash.
kubectl --context docker-desktop -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv put kv/lightdash/database \
  "PGPASSWORD=$database_password"

# Forget both in this shell.
unset lightdash_secret database_password
```

```bash
# List the key names at each path. Values are never printed.
for path in application database; do
  echo "kv/lightdash/$path:"
  kubectl --context docker-desktop -n vault exec vault-0 -- \
    env VAULT_TOKEN=root \
    vault kv get -format=json "kv/lightdash/$path" | jq -r '.data.data | keys[]'
done
```

## 9. Configure Vault Kubernetes authentication

```bash
# Teach Vault to trust identities issued by this cluster. The settings tell Vault
# where the cluster API is, which token to use when asking it to vouch for a pod,
# and which certificate authority to trust. This changes only in-memory Vault
# state; nothing is written to your Mac.
kubectl --context docker-desktop -n vault exec vault-0 -- sh -ec '
  export VAULT_TOKEN=root
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
```

```bash
# A policy that can read exactly these two paths and nothing else. The "-" means
# the policy text is piped in below rather than read from a file.
kubectl --context docker-desktop -n vault exec -i vault-0 -- \
  env VAULT_TOKEN=root \
  vault policy write lightdash - <<'EOF'
path "kv/data/lightdash/application" {
  capabilities = ["read"]
}

path "kv/metadata/lightdash/application" {
  capabilities = ["read"]
}

path "kv/data/lightdash/database" {
  capabilities = ["read"]
}

path "kv/metadata/lightdash/database" {
  capabilities = ["read"]
}
EOF
```

```bash
# A pod running as the lightdash-vault-auth ServiceAccount in the lightdash
# namespace may log in and receive that policy for one hour at a time. Neither
# exists yet; step 11 creates them.
kubectl --context docker-desktop -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault write auth/kubernetes/role/lightdash \
  bound_service_account_names=lightdash-vault-auth \
  bound_service_account_namespaces=lightdash \
  audience=vault \
  token_policies=lightdash \
  token_ttl=1h
```

## 10. Create `vso-resources.yaml`

```bash
# Open a new, empty file in the nano text editor.
nano .context/dd-external/vso-resources.yaml
```

Paste the following, then press `Control-O`, Enter, and `Control-X`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lightdash-vault-auth
  namespace: lightdash
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: local-vault
  namespace: lightdash
spec:
  address: http://vault.vault.svc.cluster.local:8200
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: lightdash-vault-auth
  namespace: lightdash
spec:
  vaultConnectionRef: local-vault
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: lightdash
    serviceAccount: lightdash-vault-auth
    audiences:
      - vault
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: lightdash-application
  namespace: lightdash
spec:
  vaultAuthRef: lightdash-vault-auth
  mount: kv
  type: kv-v2
  path: lightdash/application
  refreshAfter: 15s
  hmacSecretData: true
  destination:
    create: true
    name: lightdash-application
    transformation:
      excludeRaw: true
  rolloutRestartTargets:
    - kind: Deployment
      name: lightdash-backend
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: lightdash-database
  namespace: lightdash
spec:
  vaultAuthRef: lightdash-vault-auth
  mount: kv
  type: kv-v2
  path: lightdash/database
  refreshAfter: 15s
  hmacSecretData: true
  destination:
    create: true
    name: lightdash-database
    transformation:
      excludeRaw: true
```

`excludeRaw: true` matters on the application Secret: without it VSO adds a
`_raw` key holding the entire Vault response, and because the chart injects that
Secret with `envFrom`, `_raw` would become an environment variable containing the
whole payload.

The database Secret has no `rolloutRestartTargets`. Restarting Lightdash when the
database password changes would not help, because the running PostgreSQL still
expects the old one.

## 11. Create the PostgreSQL the chart will not manage

```bash
nano .context/dd-external/postgres.yaml
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: lightdash
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: lightdash
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          # Lightdash needs the pgvector extension, so this is not plain postgres.
          image: pgvector/pgvector:pg16
          ports:
            - containerPort: 5432
          env:
            # These three create the role and database Lightdash connects as.
            - name: POSTGRES_USER
              value: lightdash
            - name: POSTGRES_DB
              value: lightdash
            # The same Vault-backed Secret the chart reads PGPASSWORD from.
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: lightdash-database
                  key: PGPASSWORD
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "lightdash", "-d", "lightdash"]
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        # Disposable. The database is lost if this pod restarts, which is fine
        # for a lab and unacceptable anywhere else.
        - name: data
          emptyDir: {}
```

`POSTGRES_PASSWORD` is only read the first time the data directory is
initialised. Rotating it in Vault later updates the Secret but not the running
database.

## 12. Create `lightdash-values.yaml`

```bash
nano .context/dd-external/lightdash-values.yaml
```

```yaml
# Disposable local learning configuration. This file contains no credentials.

secretRefs:
  enabled: true
  application:
    # Injected in full with envFrom, so each key becomes an environment variable
    # of the same name. Must contain LIGHTDASH_SECRET.
    name: lightdash-application
  database:
    # Required because postgresql.enabled is false below. Read with secretKeyRef,
    # so only this one key reaches the pods.
    name: lightdash-database
    passwordKey: PGPASSWORD

secrets: null
existingSecret: ""

# Do not deploy the bundled database. This is what makes secretRefs.database
# take effect.
postgresql:
  enabled: false

# Where that database is, and who to connect as. None of this is secret, so it
# travels through a ConfigMap; only the password comes from the Secret above.
externalDatabase:
  host: postgres.lightdash.svc.cluster.local
  port: 5432
  user: lightdash
  database: lightdash

# Lightdash validates its whole configuration on startup and requires these
# three unconditionally, even though this lab never uploads a file. They are not
# secrets, so they belong here rather than in Vault. No object store runs here,
# so file exports will not work; everything else does.
s3:
  endpoint: http://minio.lightdash.svc.cluster.local:9000
  bucket: lightdash
  region: us-east-1

browserless-chrome:
  enabled: false

replicaCount: 1

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: false

configMap:
  SITE_URL: http://localhost:8080
  SECURE_COOKIES: "false"

# The backend runs migrations itself at startup when this is false.
migrationJob:
  enabled: false
```

`secrets: null` is significant. It stops Helm merging the chart's default
`LIGHTDASH_SECRET: changeme` into a chart-created Secret. Note also that
`externalDatabase.existingSecret` and `externalDatabase.secretKeys.passwordKey`
are ignored in strict mode: the key name comes from
`secretRefs.database.passwordKey` instead.

## 13. Validate the three files before using them

```bash
# Parse all three. A YAML typo stops you here rather than mid-install.
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_stream(File.read(f)); puts "ok #{f}" }' \
  .context/dd-external/vso-resources.yaml \
  .context/dd-external/postgres.yaml \
  .context/dd-external/lightdash-values.yaml

# Check the chart accepts your values, without touching the cluster.
"$helm_local" lint ./charts/lightdash \
  --values .context/dd-external/lightdash-values.yaml
```

## 14. Install VSO and apply the resources

```bash
# The operator that copies secrets out of Vault into Kubernetes.
"$helm_local" --kube-context docker-desktop upgrade --install vault-secrets-operator \
  hashicorp/vault-secrets-operator \
  --version 1.5.1 \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --wait \
  --timeout 5m

# The namespace everything else lives in.
kubectl --context docker-desktop create namespace lightdash

# The ServiceAccount, how to reach Vault, how to authenticate, and the two
# Vault paths to copy.
kubectl --context docker-desktop apply -f .context/dd-external/vso-resources.yaml

# Both Secrets must appear. If they do, VSO authenticated to Vault successfully.
kubectl --context docker-desktop -n lightdash wait \
  --for=create secret/lightdash-application --timeout=120s
kubectl --context docker-desktop -n lightdash wait \
  --for=create secret/lightdash-database --timeout=120s
```

```bash
# Both VaultStaticSecrets should report SYNCED and HEALTHY true.
kubectl --context docker-desktop -n lightdash get vaultstaticsecret

# Key names only; values stay hidden.
kubectl --context docker-desktop -n lightdash get secret lightdash-database \
  -o json | jq -r '.data | keys[]'
```

## 15. Start PostgreSQL

```bash
# Apply the database. It reads its password from the Secret VSO just created,
# so this must come after step 14.
kubectl --context docker-desktop apply -f .context/dd-external/postgres.yaml

# Wait until it accepts connections.
kubectl --context docker-desktop -n lightdash rollout status deployment/postgres --timeout=180s

# Prove the role and database exist, using the password from the environment
# rather than typing it.
kubectl --context docker-desktop -n lightdash exec deployment/postgres -- \
  sh -c 'psql -U lightdash -d lightdash -c "select current_user, current_database();"'
```

## 16. Side-load the application image on Apple Silicon

```bash
# Lightdash publishes linux/amd64 images only, so an arm64 node cannot pull one
# and fails with "no match for platform in manifest: not found". Pull the amd64
# build explicitly. With the containerd image store from step 3, Docker and
# Kubernetes share images, so this is all that is needed.
lightdash_tag="$(awk '/^appVersion:/ {print $2}' charts/lightdash/Chart.yaml | tr -d '"')"

docker pull --platform linux/amd64 "lightdash/lightdash:${lightdash_tag}"

# Confirm Kubernetes can see it. The chart's pull policy is IfNotPresent, so it
# uses this copy rather than pulling again.
docker image inspect "lightdash/lightdash:${lightdash_tag}" \
  --format 'present: {{.Os}}/{{.Architecture}}'
```

Skip this on an Intel Mac; the image matches your architecture and Kubernetes
pulls it normally.

## 17. Deploy the chart

```bash
# Render the chart to YAML without installing, and list any Secret it would
# create. It should print nothing at all: every secret comes from VSO.
"$helm_local" template lightdash ./charts/lightdash \
  --namespace lightdash \
  --values .context/dd-external/lightdash-values.yaml |
  awk '
    /^kind:/ { kind=$2 }
    /^metadata:/ { metadata=1; next }
    metadata && /^  name:/ {
      if (kind == "Secret") print $2
      metadata=0
    }
  '
```

```bash
# Install from THIS checkout: "./charts/lightdash" is a local path, so Helm uses
# your working copy including unreleased changes.
"$helm_local" --kube-context docker-desktop upgrade --install lightdash ./charts/lightdash \
  --namespace lightdash \
  --values .context/dd-external/lightdash-values.yaml \
  --timeout 10m

# Watch pods start. On Apple Silicon the backend is emulated and slow to boot,
# and may restart once while it waits for the database.
kubectl --context docker-desktop -n lightdash get pods --watch
```

## 18. Verify

```bash
# The backend loads the application Secret in full.
kubectl --context docker-desktop -n lightdash get deployment lightdash-backend \
  -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.secretRef.name}{"\n"}{end}'

# And takes only PGPASSWORD from the database Secret.
kubectl --context docker-desktop -n lightdash get deployment lightdash-backend \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{" <- "}{.valueFrom.secretKeyRef.name}{"\n"}{end}'

# The secret reached the container, without printing it.
kubectl --context docker-desktop -n lightdash exec deployment/lightdash-backend -- \
  sh -c 'test -n "$LIGHTDASH_SECRET" && echo "LIGHTDASH_SECRET present"'

# Lightdash created its tables in the database the chart does not manage.
kubectl --context docker-desktop -n lightdash exec deployment/postgres -- \
  sh -c 'psql -U lightdash -d lightdash -c "\dt" | head -20'
```

```bash
# Tunnel localhost:8080 to the Service. Leave this running while you use
# Lightdash; Control-C closes the tunnel.
kubectl --context docker-desktop -n lightdash port-forward service/lightdash 8080:8080
```

Open `http://localhost:8080`.

## 19. Test VSO refresh and rollout restart

Rotate only the demonstration value. Rotating `LIGHTDASH_SECRET` would leave
stored credentials undecryptable, and rotating `PGPASSWORD` would not reach the
already-initialised database.

```bash
# Change the demonstration value in Vault.
kubectl --context docker-desktop -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv patch kv/lightdash/application VSO_DEMO_VERSION=two

# Wait for VSO to react. It polls every refreshAfter (15s), rewrites the Secret,
# then stamps this annotation to restart the backend. Without this wait,
# rollout status finds the previous rollout already complete and returns at once,
# and the next command reads the old pod and prints "one".
kubectl --context docker-desktop -n lightdash wait \
  --for=jsonpath='{.spec.template.metadata.annotations.vso\.secrets\.hashicorp\.com/restartedAt}' \
  deployment/lightdash-backend --timeout=90s

kubectl --context docker-desktop -n lightdash rollout status deployment/lightdash-backend

# Should print "two".
kubectl --context docker-desktop -n lightdash exec deployment/lightdash-backend -- \
  printenv VSO_DEMO_VERSION
```

## 20. Delete the lab

```bash
# Remove everything this recipe created, in the cluster.
"$helm_local" --kube-context docker-desktop uninstall lightdash --namespace lightdash
kubectl --context docker-desktop delete namespace lightdash
kubectl --context docker-desktop delete namespace vault
kubectl --context docker-desktop delete namespace vault-secrets-operator-system
```

Deleting the namespace removes PostgreSQL, its Service, the VSO resources, and
the Secrets together, so nothing is left behind. Unlike the Kind recipe there is
no bundled `postgresql` StatefulSet to clean up by hand: because the chart never
created the database, `helm uninstall` was never responsible for it.

To remove the cluster itself, use **Settings, Kubernetes, Disable Kubernetes**,
or **Reset Kubernetes cluster** to empty it while keeping it enabled. If you
turned on the containerd image store in step 3 only for this lab, you can turn
it off again in **Settings, General**.

The files under `.context/dd-external/` remain for reference.
