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
# Move to the top of the Git repository, wherever you cloned it.
cd "$(git rev-parse --show-toplevel)"

# Show which branch you are on. This recipe deploys whatever is checked out.
git branch --show-current

# Confirm Git ignores .context/, the scratch folder this recipe writes into.
git check-ignore -v .context/
```

The first command reports the branch that will be deployed; this recipe installs
whatever is checked out, so confirm it is the branch you intend. The second
command should show that `.context/` is ignored by the repository. Do not
continue if it is not ignored, because this recipe writes working files there.

## 2. Check Docker and the Mac architecture

```bash
# Check Docker is running, and see how much CPU and memory it may use.
docker info --format 'server={{.ServerVersion}} cpus={{.NCPU}} memory={{.MemTotal}}'

# Print the Mac's chip: arm64 is Apple Silicon, x86_64 is Intel.
uname -m
```

This lab was prepared for an Apple Silicon Mac, where `uname -m` prints
`arm64`. On an Intel Mac, replace `darwin-arm64` with `darwin-amd64` in the
download commands.

## 3. Create the local directory structure

```bash
# Somewhere to keep the kind and helm binaries this recipe downloads.
mkdir -p .context/local-vso/bin

# Three folders that hold this lab's Helm settings, downloaded chart index,
# and plugins, so none of it mixes with the Helm setup you already have.
mkdir -p .context/local-vso/helm/config
mkdir -p .context/local-vso/helm/cache
mkdir -p .context/local-vso/helm/data
```

These commands create directories only. They do not create a cluster or modify
your global Kubernetes configuration.

## 4. Download and verify Kind

```bash
# Pin the version and platform so everyone following this gets the same binary.
kind_version='v0.33.0'
kind_platform='darwin-arm64'   # Intel Mac: change to darwin-amd64
kind_destination="$PWD/.context/local-vso/bin/kind"

# Download the Kind program itself.
curl -fsSL \
  "https://kind.sigs.k8s.io/dl/${kind_version}/kind-${kind_platform}" \
  -o "$kind_destination"

# Download the fingerprint the Kind project published for that exact file.
curl -fsSL \
  "https://kind.sigs.k8s.io/dl/${kind_version}/kind-${kind_platform}.sha256sum" \
  -o "$PWD/.context/local-vso/bin/kind.sha256sum"

# Fingerprint what you actually downloaded and compare the two. `test` prints
# nothing on success and fails the command if they differ.
kind_expected_checksum="$(awk '{print $1}' .context/local-vso/bin/kind.sha256sum)"
kind_actual_checksum="$(shasum -a 256 "$kind_destination" | awk '{print $1}')"
test "$kind_actual_checksum" = "$kind_expected_checksum"

# Mark it runnable and confirm it works.
chmod +x "$kind_destination"
"$kind_destination" version
```

`test` prints nothing when the checksums match. It returns an error and stops if
the download does not match the Kind project's published checksum.

## 5. Download and verify Helm 3

The system Helm installation may be a different major version. This lab keeps
Helm 3.21.4 isolated under `.context/` instead of replacing it.

```bash
# 3.21.4 is the version this repository's CI uses.
helm_version='v3.21.4'
helm_platform='darwin-arm64'   # Intel Mac: change to darwin-amd64
helm_archive="$PWD/.context/local-vso/helm-${helm_version}-${helm_platform}.tar.gz"
helm_checksum_file="${helm_archive}.sha256sum"

# Download the Helm archive.
curl -fsSL \
  "https://get.helm.sh/helm-${helm_version}-${helm_platform}.tar.gz" \
  -o "$helm_archive"

# Download its published fingerprint.
curl -fsSL \
  "https://get.helm.sh/helm-${helm_version}-${helm_platform}.tar.gz.sha256sum" \
  -o "$helm_checksum_file"

# Verify the download matches before unpacking it.
helm_expected_checksum="$(awk '{print $1}' "$helm_checksum_file")"
helm_actual_checksum="$(shasum -a 256 "$helm_archive" | awk '{print $1}')"
test "$helm_actual_checksum" = "$helm_expected_checksum"

# Unpack, copy the binary next to kind, and confirm the version.
tar -xzf "$helm_archive" -C .context/local-vso
cp .context/local-vso/darwin-arm64/helm .context/local-vso/bin/helm
chmod +x .context/local-vso/bin/helm
.context/local-vso/bin/helm version --short
```

## 6. Create the isolated Kind cluster and kubeconfig

```bash
# Shorthand so you do not retype the path to the kind binary.
kind_local="$PWD/.context/local-vso/bin/kind"

# Create the cluster. This is the single Docker container you will see running.
# --kubeconfig writes the connection details to their own file instead of your
# usual ~/.kube/config; --wait blocks until the control plane answers.
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
# Point THIS terminal at the lab cluster. Your normal kubectl context is
# untouched, and a new terminal will not have this set.
export KUBECONFIG="$PWD/.context/local-vso/kubeconfig"

# Which cluster will kubectl talk to? Must say kind-lightdash-vso.
kubectl config current-context

# One node, and it should be Ready.
kubectl get nodes
```

The context must be `kind-lightdash-vso`. Do not continue if it names Okteto or
GKE.

## 7. Configure isolated Helm state

```bash
# Send Helm's settings, cache, and plugins into .context/ rather than your
# home folder, so this lab cannot alter your existing Helm setup.
export HELM_CONFIG_HOME="$PWD/.context/local-vso/helm/config"
export HELM_CACHE_HOME="$PWD/.context/local-vso/helm/cache"
export HELM_DATA_HOME="$PWD/.context/local-vso/helm/data"

# Shorthand for the Helm 3 binary downloaded in step 5.
helm_local="$PWD/.context/local-vso/bin/helm"

# Register HashiCorp's chart repository, where the Vault and VSO charts live.
"$helm_local" repo add hashicorp https://helm.releases.hashicorp.com --force-update

# Download that repository's catalogue of charts and versions.
"$helm_local" repo update
```

The two commands register the HashiCorp chart repository and download its
catalogue, writing four files:

```text
helm/config/repositories.yaml               the repository list, here just hashicorp
helm/config/repositories.lock               lock file guarding concurrent writes
helm/cache/repository/hashicorp-index.yaml  every HashiCorp chart and version (~340 KB)
helm/cache/repository/hashicorp-charts.txt  chart-name index used for completion
```

`helm/data/` stays empty. It would hold Helm plugins, and this recipe installs
none. None of this is a credential, and nothing is installed into the cluster
yet; step 11 deploys the first workload.

Because the three `HELM_*_HOME` variables point into `.context/`, adding the
repository does not touch your normal Helm configuration: `hashicorp` will not
appear in `helm repo list` in another terminal. That isolation comes from the
exported variables, so run the remaining steps in this same shell, or re-export
all four lines in a new one.

## 8. Create `vso-resources.yaml`

Open the file in an editor:

```bash
# Open a new, empty file in the nano text editor.
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
# Open a second new, empty file.
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
# Parse both files you just typed. A YAML typo stops you here, rather than
# halfway through an install. Ruby ships with macOS, so there is nothing to add.
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_stream(File.read(f)); puts "ok #{f}" }' \
  .context/local-vso/vso-resources.yaml \
  .context/local-vso/lightdash-values.yaml

# Check the chart accepts your values, still without touching the cluster.
"$helm_local" lint ./charts/lightdash \
  --values .context/local-vso/lightdash-values.yaml
```

At this point the tools, local cluster, kubeconfig, Helm state, and two lab YAML
files are prepared. The next sections install the workloads.

## 11. Install Vault in development mode

```bash
# Install Vault into its own namespace.
#   server.dev.enabled=true  in-memory storage, unseals itself, root token "root"
#   injector.enabled=false   skip Vault's sidecar injector; this lab uses VSO
"$helm_local" upgrade --install vault hashicorp/vault \
  --version 0.34.1 \
  --namespace vault \
  --create-namespace \
  --set server.dev.enabled=true \
  --set injector.enabled=false \
  --wait \
  --timeout 5m

# Wait until the Vault pod is genuinely ready. Helm's --wait is not enough here;
# the note below explains why.
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s

# Show what was created.
kubectl -n vault get pods,services

# Ask Vault about itself. Expect Initialized true and Sealed false.
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault status
```

That wait is not redundant with Helm's `--wait`. The Vault chart sets the
StatefulSet's `updateStrategy` to `OnDelete`, and Helm 3 treats any StatefulSet
that is not `RollingUpdate` as instantly ready, so `--wait` returns while
`vault-0` is still `ContainerCreating`. Without it the next command fails with:

```text
error: unable to upgrade connection: container not found ("vault")
```

If you hit that, nothing is broken. Wait for the pod to report `1/1 Running`
and run the command again. `kubectl rollout status` does not help here; it
refuses to report on an `OnDelete` StatefulSet.

`vault status` should report `Initialized true` and `Sealed false`. Development
mode unseals itself; a real Vault would not.

## 12. Create the Vault secret

```bash
# Turn on a key-value store, version 2, reachable at the path kv/.
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault secrets enable -path=kv kv-v2

# Generate a random 64-character secret on your Mac. Lightdash signs cookies and
# encrypts stored warehouse credentials with it.
local_lightdash_secret="$(openssl rand -hex 32)"

# Store it in Vault, alongside a harmless value used in step 17 to prove that
# refresh works.
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv put kv/lightdash/application \
  "LIGHTDASH_SECRET=$local_lightdash_secret" \
  "VSO_DEMO_VERSION=one"

# Forget the secret in this shell so it is not left in your session.
unset local_lightdash_secret
```

Verify key names without revealing values:

```bash
# List only the key NAMES stored at that path. The values are never printed.
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv get -format=json kv/lightdash/application |
  jq -r '.data.data | keys[]'
```

## 13. Configure Vault Kubernetes authentication

```bash
# Teach Vault to trust identities issued by this Kubernetes cluster. The three
# settings tell Vault where the cluster's API is, which token to use when asking
# the cluster to vouch for a pod, and which certificate authority to trust.
# All of this runs inside the Vault pod, so nothing is written to your Mac.
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
# Create a policy allowing read access to exactly one secret and nothing else.
# The "-" means the policy text is piped in below instead of read from a file.
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
# Tie the two together: a pod running as the lightdash-vault-auth ServiceAccount
# in the lightdash namespace may log in and receive the lightdash policy, for one
# hour at a time. Neither exists yet; step 14 creates them, and Vault does not
# mind binding a role to a name that appears later.
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
# Install the operator that copies secrets out of Vault into Kubernetes.
"$helm_local" upgrade --install vault-secrets-operator \
  hashicorp/vault-secrets-operator \
  --version 1.5.1 \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --wait \
  --timeout 5m

# Create the namespace Lightdash will run in.
kubectl create namespace lightdash

# Apply the four objects from step 8: the ServiceAccount pods log in as, how to
# reach Vault, how to authenticate, and which Vault path to copy where.
kubectl apply -f .context/local-vso/vso-resources.yaml

# Wait for the Secret to appear. If this succeeds, VSO authenticated to Vault,
# read the secret, and wrote it into Kubernetes.
kubectl wait \
  --namespace lightdash \
  --for=create \
  secret/lightdash-application \
  --timeout=120s
```

Verify the operator state and Secret key names:

```bash
# The three VSO objects and whether they are healthy.
kubectl -n lightdash get vaultconnection,vaultauth,vaultstaticsecret

# Detailed status and recent events for the sync. Look here first if it failed.
kubectl -n lightdash describe vaultstaticsecret lightdash-application

# Key names inside the Secret VSO produced. Values stay hidden.
kubectl -n lightdash get secret lightdash-application -o json |
  jq -r '.data | keys[]'
```

## 15. Render and deploy this branch's chart

List rendered Secret names:

```bash
# Render the chart to YAML without installing anything, then list the names of
# any Secret it would create. This proves the chart is not making its own.
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
# Install from THIS checkout. "./charts/lightdash" is a local path, so Helm uses
# your working copy including unreleased changes, not the published chart.
"$helm_local" upgrade --install lightdash ./charts/lightdash \
  --namespace lightdash \
  --values .context/local-vso/lightdash-values.yaml \
  --timeout 10m

# Watch pods start. New lines appear only as something changes.
kubectl -n lightdash get pods --watch
```

Press `Control-C` when PostgreSQL and the backend are ready.

## 16. Verify and open Lightdash

Confirm that the backend references VSO's Secret:

```bash
# Print the Secrets the backend loads in full. Expect lightdash-application,
# the one VSO created, which is the whole point of the lab.
kubectl -n lightdash get deployment lightdash-backend \
  -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.secretRef.name}{"\n"}{end}'
```

Forward the Service to the Mac:

```bash
# Tunnel localhost:8080 on your Mac to the Service in the cluster. Leave this
# running while you use Lightdash; Control-C closes the tunnel.
kubectl -n lightdash port-forward service/lightdash 8080:8080
```

Open `http://localhost:8080`.

## 17. Test VSO refresh and rollout restart

Do not rotate `LIGHTDASH_SECRET`: Lightdash uses it to encrypt stored
credentials. Change only the harmless demonstration value:

```bash
# Change only the demonstration value in Vault.
kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=root \
  vault kv patch kv/lightdash/application \
  VSO_DEMO_VERSION=two

# VSO re-reads Vault within refreshAfter (15s), updates the Secret, and restarts
# the backend because vso-resources.yaml lists it in rolloutRestartTargets.
# Environment variables never change inside a running container, so without that
# restart the new value would never reach the app.
kubectl -n lightdash rollout status deployment/lightdash-backend

# Read the value from inside the restarted pod. It should print "two".
kubectl -n lightdash exec deployment/lightdash-backend -- \
  printenv VSO_DEMO_VERSION
```

The last command should print `two`.

## 18. Delete the lab

This permanently removes the local Vault secrets, PostgreSQL data, VSO, and
Lightdash installation:

```bash
# Delete the cluster and everything inside it: Vault and its secrets, VSO,
# PostgreSQL and its data, and Lightdash. The Docker container disappears too.
"$kind_local" delete cluster --name lightdash-vso
```

The files under `.context/local-vso/` remain available so you can inspect them
or recreate the cluster later.
