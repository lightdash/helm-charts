# Option: HCP Vault Dedicated with Vault Agent Injector

[Return to the main guide](../../gke-production-deployment-guide.md#8-deliver-secrets)

This is an advanced, optional integration for organizations that already require
HCP Vault Agent Injector. Kubernetes Secrets remain the recommended starting
point for this guide.

## Understand the current hybrid limitation

Vault Agent Injector mutates Pods and renders secrets into an in-memory volume at
`/vault/secrets`. It does not create Kubernetes Secrets, and Kubernetes cannot
populate an environment variable from a file. This chart can wrap the backend
and worker commands so they source an injected file, but two current chart
constraints prevent a pure Injector deployment:

1. Every workload reads `PGPASSWORD` through an unconditional `secretKeyRef`.
2. The migration Job command is fixed and cannot source the injected file.

Therefore this option uses:

- injected files for the backend and workers' `LIGHTDASH_SECRET`,
  `S3_ACCESS_KEY`, and `S3_SECRET_KEY`;
- `lightdash-database` Kubernetes Secret for `PGPASSWORD` on every workload;
- `lightdash-application` Kubernetes Secret for the migration Job's
  `LIGHTDASH_SECRET`.

It creates no `lightdash-s3` Kubernetes Secret. If avoiding all Kubernetes Secret
values is a hard requirement, the chart needs further API changes before this
option can meet it.

## 1. Prepare HCP Vault

Complete the [shared HCP Vault and GCP authentication setup](hcp-vault-gcp-foundation.md).
Return here with `VAULT_ADDR`, `HCP_NAMESPACE`, GCP auth, and the three KV paths
ready.

This option currently assumes the documented Cloud SQL setup. It reuses the
`lightdash-cloud-sql` GCP service account already attached to the `lightdash`
Kubernetes service account, so one Pod does not need to impersonate two GCP
identities.

## 2. Allow the workload identity to log in to Vault

The injected Agent uses GCP IAM auto-auth through GKE Workload Identity. Permit
the Cloud SQL GCP service account to sign only its own login JWT, then bind it to
the narrow Vault policy:

```bash
export INJECTOR_GSA="lightdash-cloud-sql"

vault policy write lightdash-injector-read \
  docs/gke/vault-injector-policy.hcl

gcloud iam service-accounts add-iam-policy-binding \
  "$INJECTOR_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="serviceAccount:$INJECTOR_GSA@$PROJECT_ID.iam.gserviceaccount.com"

vault write auth/gcp/role/lightdash-gke-injector \
  type=iam \
  policies=lightdash-injector-read \
  max_jwt_exp=3600 \
  token_ttl=20m \
  token_max_ttl=30m \
  bound_service_accounts="$INJECTOR_GSA@$PROJECT_ID.iam.gserviceaccount.com"
```

The grant is self-impersonation only. Do not grant Token Creator across the
project.

## 3. Install the Injector in external-Vault mode

The official Vault Helm chart installs only the admission webhook; the Vault
server remains HCP Vault Dedicated.

```bash
helm3 repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm3 repo update
kubectl create namespace vault-agent-injector \
  --dry-run=client -o yaml | kubectl apply -f -

helm3 upgrade --install vault-agent-injector hashicorp/vault \
  --namespace vault-agent-injector \
  --version 0.34.1 \
  --set server.enabled=false \
  --set injector.enabled=true \
  --set injector.replicas=2 \
  --set injector.webhook.failurePolicy=Fail \
  --set injector.metrics.enabled=true \
  --set injector.authPath=auth/gcp \
  --set-string global.externalVaultAddr="$VAULT_ADDR" \
  --wait \
  --timeout 10m

kubectl -n vault-agent-injector get deployments,pods,services
kubectl get mutatingwebhookconfigurations \
  -l app.kubernetes.io/instance=vault-agent-injector
```

On a private GKE cluster, the Kubernetes control plane must reach the Injector
webhook on TCP 8080. If Pod creation reports webhook timeouts, have the network
administrator allow TCP 8080 from the cluster's control-plane CIDR. Do not add a
broad internet firewall rule.

## 4. Create the two unavoidable Kubernetes Secrets

Read the authoritative values from Vault and pipe generated manifests directly
to Kubernetes. The values are not written to a YAML file or printed:

```bash
export DB_PASSWORD="$(vault kv get -field=PGPASSWORD \
  kv/apps/lightdash/database)"
export LIGHTDASH_SECRET="$(vault kv get -field=LIGHTDASH_SECRET \
  kv/apps/lightdash/application)"

kubectl -n "$NAMESPACE" create secret generic lightdash-database \
  --from-literal=PGPASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic lightdash-application \
  --from-literal=LIGHTDASH_SECRET="$LIGHTDASH_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

unset DB_PASSWORD LIGHTDASH_SECRET S3_ACCESS_KEY S3_SECRET_KEY
rm -P .context/gke/storage-credential.json 2>/dev/null || true
```

Confirm names and keys without decoding values:

```bash
kubectl -n "$NAMESPACE" get secret \
  lightdash-database lightdash-application
test -z "$(kubectl -n "$NAMESPACE" get secret lightdash-s3 \
  --ignore-not-found -o name)"
```

Do not run Helm unless the first command succeeds.

## 5. Prepare the Injector Helm fragment

```bash
cp docs/gke/values/secrets-vault-injector.yaml \
  .context/gke/secrets-values.yaml
sed -i '' "s/REPLACE_PROJECT_ID/$PROJECT_ID/g" \
  .context/gke/secrets-values.yaml
sed -i '' "s|REPLACE_HCP_VAULT_PUBLIC_URL|$VAULT_ADDR|g" \
  .context/gke/secrets-values.yaml
sed -i '' "s/vault.hashicorp.com\/namespace: \"admin\"/vault.hashicorp.com\/namespace: \"$HCP_NAMESPACE\"/g" \
  .context/gke/secrets-values.yaml
```

The fragment:

- asks the Injector to run a pre-population init container only;
- mounts `/vault/secrets` only in the `lightdash` application container, not the
  Cloud SQL proxy;
- uses GCP IAM auth and verifies HCP Vault TLS;
- renders a shell-safe `/vault/secrets/env` file;
- wraps backend and worker commands with `. /vault/secrets/env`;
- reads the two unavoidable Kubernetes Secrets per key.

Pre-population-only avoids a permanent sidecar because changing a rendered file
cannot update an already-running process environment. Rotation still requires a
Pod restart.

## 6. Validate and verify injection

Continue with the shared Helm validation. The render should contain Injector
annotations, wrapped commands, two `secretKeyRef` names, and no `kind: Secret`:

```bash
grep -nE 'vault.hashicorp.com/agent-inject|/vault/secrets/env|lightdash-(database|application)' \
  .context/gke/rendered.yaml
```

After deployment, find a backend Pod and check the injected init container and
file without displaying the file:

```bash
export BACKEND_POD="$(kubectl -n "$NAMESPACE" get pod \
  -l app.kubernetes.io/component=backend \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl -n "$NAMESPACE" get pod "$BACKEND_POD" \
  -o jsonpath='{.spec.initContainers[*].name}{"\n"}'
kubectl -n "$NAMESPACE" logs "$BACKEND_POD" \
  -c vault-agent-init --tail=100
kubectl -n "$NAMESPACE" exec "$BACKEND_POD" \
  -c lightdash -- test -r /vault/secrets/env
```

Never `cat` the injected file into terminal logs.

## Rotation and tradeoffs

After changing Vault values:

1. Recreate `lightdash-database` or `lightdash-application` when that source path
   changed.
2. Restart every enabled Lightdash Deployment so the Agent init container renders
   fresh values and the wrapper sources them.
3. Verify readiness and a storage operation before revoking old credentials.

```bash
kubectl -n "$NAMESPACE" rollout restart deployment/lightdash-backend
kubectl -n "$NAMESPACE" rollout restart deployment/lightdash-worker
```

Sourcing the file puts values into the Lightdash process environment, where they
may be visible through `/proc/<pid>/environ` to sufficiently privileged actors.
The Injector removes the S3 and runtime application values from the Kubernetes
API, but it does not remove process-environment exposure or this chart's two
required Kubernetes Secrets.

References: [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector),
[Injector annotations](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector/annotations),
[external Vault Helm mode](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/examples/external),
and [Vault Agent GCP auto-auth](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/gcp).
