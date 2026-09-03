# Local Lightdash + Vault Secrets Operator lab

This lab deploys the current local Lightdash Helm chart into a disposable Kind
cluster. It uses a local Vault development server and Vault Secrets Operator
(VSO), with no GCP or HCP resources.

> **Local learning only:** Vault development mode uses HTTP, an in-memory
> storage backend, and a known root token. Its data disappears when the Vault
> pod or Kind cluster is removed. Never use this configuration for production.

## The tools this recipe uses

**Kind** stands for Kubernetes in Docker. It runs a real Kubernetes cluster
inside Docker containers on your machine, so this recipe needs no cloud account
and costs nothing. It is a genuine cluster rather than a simulator, so the
chart, secret reconciliation, and pod restarts behave as they would in
production. The cluster is disposable: the last step deletes it and leaves
nothing behind. This repository's CI uses Kind the same way to install the
chart on every pull request.

**Vault** stores secrets. Here it runs in development mode inside the cluster,
which is convenient but insecure, and is the reason this recipe is for learning
only.

**Vault Secrets Operator (VSO)** is the bridge between the two. Kubernetes
cannot read from Vault directly, so VSO watches for a resource you create, reads
the Vault path it names, and writes the result into an ordinary Kubernetes
Secret. The chart then references that Secret through `secretRefs`, exactly as
it would with any other externally managed Secret.

Everything is kept separate from your existing setup: the cluster gets its own
kubeconfig and Helm state under `.context/`, so your usual `kubectl` context is
never repointed.

## What this lab creates

```text
local Git checkout -> local Helm chart -> Kind -> Lightdash
local Vault -> VSO -> Kubernetes Secret -> Lightdash
Lightdash -> bundled ephemeral PostgreSQL
browser -> kubectl port-forward -> Lightdash Service
```

Files under `.context/local-vso/`:

| Path | Created by | Purpose |
|---|---|---|
| `bin/kind` | Download step | Creates the local Kubernetes cluster |
| `bin/helm` | Download step | Helm 3 version used by this repository's CI |
| `kubeconfig` | `kind create cluster` | Isolates this lab from other Kubernetes contexts |
| `helm/` | Helm repository commands | Isolated Helm configuration and cache |
| `vso-resources.yaml` | You create it below | Connects VSO to local Vault |
| `lightdash-values.yaml` | You create it below | Configures the branch chart for the local lab |

## 1. Confirm the workspace and ignore rule

```bash
# Run every command in this recipe from the repository root.
cd "$(git rev-parse --show-toplevel)"
git branch --show-current
git check-ignore -v .context/
```

The first command reports the branch that will be deployed; this recipe installs
whatever is checked out, so confirm it is the branch you intend. The second
command should show that `.context/` is ignored by the repository. Do not
continue if it is not ignored, because this recipe writes working files there.

## 2. Check Docker and the Mac architecture

```bash
docker info --format 'server={{.ServerVersion}} cpus={{.NCPU}} memory={{.MemTotal}}'
uname -m
```

This lab was prepared for an Apple Silicon Mac, where `uname -m` prints
`arm64`. On an Intel Mac, replace `darwin-arm64` with `darwin-amd64` in the
download commands.

## 3. Create the local directory structure

```bash
mkdir -p .context/local-vso/bin
mkdir -p .context/local-vso/helm/config
mkdir -p .context/local-vso/helm/cache
mkdir -p .context/local-vso/helm/data
```

These commands create directories only. They do not create a cluster or modify
your global Kubernetes configuration.

## 4. Download and verify Kind

```bash
kind_version='v0.33.0'
kind_platform='darwin-arm64'
kind_destination="$PWD/.context/local-vso/bin/kind"

curl -fsSL \
  "https://kind.sigs.k8s.io/dl/${kind_version}/kind-${kind_platform}" \
  -o "$kind_destination"

curl -fsSL \
  "https://kind.sigs.k8s.io/dl/${kind_version}/kind-${kind_platform}.sha256sum" \
  -o "$PWD/.context/local-vso/bin/kind.sha256sum"

kind_expected_checksum="$(awk '{print $1}' .context/local-vso/bin/kind.sha256sum)"
kind_actual_checksum="$(shasum -a 256 "$kind_destination" | awk '{print $1}')"
test "$kind_actual_checksum" = "$kind_expected_checksum"

chmod +x "$kind_destination"
"$kind_destination" version
```

`test` prints nothing when the checksums match. It returns an error and stops if
the download does not match the Kind project's published checksum.

## 5. Download and verify Helm 3

The system Helm installation may be a different major version. This lab keeps
Helm 3.21.4 isolated under `.context/` instead of replacing it.

```bash
helm_version='v3.21.4'
helm_platform='darwin-arm64'
helm_archive="$PWD/.context/local-vso/helm-${helm_version}-${helm_platform}.tar.gz"
helm_checksum_file="${helm_archive}.sha256sum"

curl -fsSL \
  "https://get.helm.sh/helm-${helm_version}-${helm_platform}.tar.gz" \
  -o "$helm_archive"

curl -fsSL \
  "https://get.helm.sh/helm-${helm_version}-${helm_platform}.tar.gz.sha256sum" \
  -o "$helm_checksum_file"

helm_expected_checksum="$(awk '{print $1}' "$helm_checksum_file")"
helm_actual_checksum="$(shasum -a 256 "$helm_archive" | awk '{print $1}')"
test "$helm_actual_checksum" = "$helm_expected_checksum"

tar -xzf "$helm_archive" -C .context/local-vso
cp .context/local-vso/darwin-arm64/helm .context/local-vso/bin/helm
chmod +x .context/local-vso/bin/helm
.context/local-vso/bin/helm version --short
```

## 6. Create the isolated Kind cluster and kubeconfig

```bash
kind_local="$PWD/.context/local-vso/bin/kind"

"$kind_local" create cluster \
  --name lightdash-vso \
  --kubeconfig "$PWD/.context/local-vso/kubeconfig" \
  --wait 180s
```

Kind creates `.context/local-vso/kubeconfig`; do not create that file manually.
Because it is separate from the default kubeconfig, creating this cluster does
not replace the global `kubectl` context.

Point the current terminal at the local kubeconfig:

```bash
export KUBECONFIG="$PWD/.context/local-vso/kubeconfig"
kubectl config current-context
kubectl get nodes
```

The context must be `kind-lightdash-vso`. Do not continue if it names Okteto or
GKE.

## 7. Configure isolated Helm state

```bash
export HELM_CONFIG_HOME="$PWD/.context/local-vso/helm/config"
export HELM_CACHE_HOME="$PWD/.context/local-vso/helm/cache"
export HELM_DATA_HOME="$PWD/.context/local-vso/helm/data"
helm_local="$PWD/.context/local-vso/bin/helm"

"$helm_local" repo add hashicorp https://helm.releases.hashicorp.com --force-update
"$helm_local" repo update
```

These Helm commands populate `.context/local-vso/helm/`. They do not change the
system Helm installation.

## 8. Create `vso-resources.yaml`

Open the file in an editor:

```bash
nano .context/local-vso/vso-resources.yaml
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
```

This file contains paths, object names, and configuration only. It contains no
credential values.

## 9. Create `lightdash-values.yaml`

Open the file:

```bash
nano .context/local-vso/lightdash-values.yaml
```

Paste and save:

```yaml
# Disposable local learning configuration. This file contains no credentials.

secretRefs:
  enabled: true
  application:
    name: lightdash-application

secrets: null
existingSecret: ""

postgresql:
  enabled: true
  primary:
    persistence:
      enabled: false

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

migrationJob:
  enabled: false
```

`secrets: null` is significant. It prevents Helm from merging the chart's
default `LIGHTDASH_SECRET: changeme` into a chart-created application Secret.
VSO will create the application Secret instead.

## 10. Validate the two files before using them

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_stream(File.read(f)); puts "ok #{f}" }' \
  .context/local-vso/vso-resources.yaml \
  .context/local-vso/lightdash-values.yaml

"$helm_local" lint ./charts/lightdash \
  --values .context/local-vso/lightdash-values.yaml
```

At this point the tools, local cluster, kubeconfig, Helm state, and two lab YAML
files are prepared. The next sections install the workloads.

## 11. Install Vault in development mode

```bash
"$helm_local" upgrade --install vault hashicorp/vault \
  --version 0.34.1 \
  --namespace vault \
  --create-namespace \
  --set server.dev.enabled=true \
  --set injector.enabled=false \
  --wait \
  --timeout 5m

kubectl -n vault get pods,services
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault status
```

## 12. Create the Vault secret

```bash
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault secrets enable -path=kv kv-v2

local_lightdash_secret="$(openssl rand -hex 32)"

kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv put kv/lightdash/application \
  "LIGHTDASH_SECRET=$local_lightdash_secret" \
  "VSO_DEMO_VERSION=one"

unset local_lightdash_secret
```

Verify key names without revealing values:

```bash
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv get -format=json kv/lightdash/application |
  jq -r '.data.data | keys[]'
```

## 13. Configure Vault Kubernetes authentication

```bash
kubectl -n vault exec vault-0 -- sh -ec '
  export VAULT_TOKEN=root
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
```

Create the least-privilege read policy:

```bash
kubectl -n vault exec -i vault-0 -- \
  env VAULT_TOKEN=root \
  vault policy write lightdash - <<'EOF'
path "kv/data/lightdash/application" {
  capabilities = ["read"]
}

path "kv/metadata/lightdash/application" {
  capabilities = ["read"]
}
EOF
```

Bind the Vault role to the future Kubernetes ServiceAccount:

```bash
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault write auth/kubernetes/role/lightdash \
  bound_service_account_names=lightdash-vault-auth \
  bound_service_account_namespaces=lightdash \
  audience=vault \
  token_policies=lightdash \
  token_ttl=1h
```

## 14. Install VSO and apply its resources

```bash
"$helm_local" upgrade --install vault-secrets-operator \
  hashicorp/vault-secrets-operator \
  --version 1.5.1 \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --wait \
  --timeout 5m

kubectl create namespace lightdash
kubectl apply -f .context/local-vso/vso-resources.yaml

kubectl wait \
  --namespace lightdash \
  --for=create \
  secret/lightdash-application \
  --timeout=120s
```

Verify the operator state and Secret key names:

```bash
kubectl -n lightdash get vaultconnection,vaultauth,vaultstaticsecret
kubectl -n lightdash describe vaultstaticsecret lightdash-application
kubectl -n lightdash get secret lightdash-application -o json |
  jq -r '.data | keys[]'
```

## 15. Render and deploy this branch's chart

List rendered Secret names:

```bash
"$helm_local" template lightdash ./charts/lightdash \
  --namespace lightdash \
  --values .context/local-vso/lightdash-values.yaml |
  awk '
    /^kind:/ { kind=$2 }
    /^metadata:/ { metadata=1; next }
    metadata && /^  name:/ {
      if (kind == "Secret") print $2
      metadata=0
    }
  '
```

The only result should be `lightdash-postgresql`. The bundled PostgreSQL chart
owns that Secret; VSO owns `lightdash-application`.

Deploy the local chart, not a published chart reference:

```bash
"$helm_local" upgrade --install lightdash ./charts/lightdash \
  --namespace lightdash \
  --values .context/local-vso/lightdash-values.yaml \
  --timeout 10m

kubectl -n lightdash get pods --watch
```

Press `Control-C` when PostgreSQL and the backend are ready.

## 16. Verify and open Lightdash

Confirm that the backend references VSO's Secret:

```bash
kubectl -n lightdash get deployment lightdash-backend \
  -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.secretRef.name}{"\n"}{end}'
```

Forward the Service to the Mac:

```bash
kubectl -n lightdash port-forward service/lightdash 8080:8080
```

Open `http://localhost:8080`.

## 17. Test VSO refresh and rollout restart

Do not rotate `LIGHTDASH_SECRET`: Lightdash uses it to encrypt stored
credentials. Change only the harmless demonstration value:

```bash
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv patch kv/lightdash/application \
  VSO_DEMO_VERSION=two

kubectl -n lightdash rollout status deployment/lightdash-backend
kubectl -n lightdash exec deployment/lightdash-backend -- \
  printenv VSO_DEMO_VERSION
```

The last command should print `two`.

## 18. Delete the lab

This permanently removes the local Vault secrets, PostgreSQL data, VSO, and
Lightdash installation:

```bash
"$kind_local" delete cluster --name lightdash-vso
```

The files under `.context/local-vso/` remain available so you can inspect them
or recreate the cluster later.
