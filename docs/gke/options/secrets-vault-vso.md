# Option: HCP Vault Dedicated and Vault Secrets Operator

[Return to the main guide](../../gke-production-deployment-guide.md#8-deliver-secrets)

This optional integration keeps credentials out of Helm values. Vault Secrets
Operator (VSO) authenticates from GKE through Workload Identity, reads three
narrow Vault paths, and creates three Kubernetes Secrets.

Kubernetes Secrets are the simpler recommended starting point. Choose VSO when
your organization already operates HCP Vault and needs centralized rotation,
policy, and auditing.

## 1. Prepare HCP Vault

Complete the [shared HCP Vault and GCP authentication setup](hcp-vault-gcp-foundation.md).
Return here with `VAULT_ADDR`, `HCP_NAMESPACE`, and the three Vault paths ready.

## 2. Create the VSO Google identity

```bash
export VSO_GSA="lightdash-vso"

gcloud iam service-accounts create "$VSO_GSA" \
  --display-name="Vault Secrets Operator authentication"

gcloud iam service-accounts add-iam-policy-binding \
  "$VSO_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[$NAMESPACE/lightdash-vault-auth]"

gcloud iam service-accounts add-iam-policy-binding \
  "$VSO_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="serviceAccount:$VSO_GSA@$PROJECT_ID.iam.gserviceaccount.com"

vault write auth/gcp/role/lightdash-gke \
  type=iam \
  policies=lightdash-read \
  max_jwt_exp=3600 \
  token_ttl=20m \
  token_max_ttl=30m \
  bound_service_accounts="$VSO_GSA@$PROJECT_ID.iam.gserviceaccount.com"
```

The Token Creator grant is self-impersonation only, not project-wide.

## 3. Install pinned VSO

```bash
helm3 repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm3 repo update
kubectl create namespace vault-secrets-operator \
  --dry-run=client -o yaml | kubectl apply -f -

helm3 upgrade --install vault-secrets-operator \
  hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator \
  --version 1.5.0 \
  --wait \
  --timeout 10m
```

## 4. Apply the Vault resources

```bash
cp docs/gke/vault-resources.yaml .context/gke/vault-resources.yaml
sed -i '' "s/REPLACE_PROJECT_ID/$PROJECT_ID/g" \
  .context/gke/vault-resources.yaml
sed -i '' "s|REPLACE_HCP_VAULT_PUBLIC_URL|$VAULT_ADDR|g" \
  .context/gke/vault-resources.yaml
sed -i '' "s/namespace: \"admin\"/namespace: \"$HCP_NAMESPACE\"/g" \
  .context/gke/vault-resources.yaml

kubectl apply -f .context/gke/vault-resources.yaml
```

The resources use `excludeRaw`, refresh every 60 seconds, and restart both
Lightdash Deployments after rotation.

## 5. Wait for all destination Secrets

Do not run Helm until this succeeds:

```bash
for ATTEMPT in {1..60}; do
  if kubectl -n "$NAMESPACE" get secret \
    lightdash-application lightdash-database lightdash-s3 >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

kubectl -n "$NAMESPACE" get secret \
  lightdash-application lightdash-database lightdash-s3
kubectl -n "$NAMESPACE" get vaultauth,vaultconnection,vaultstaticsecret
```

Check key names without decoding values:

```bash
for SECRET_NAME in lightdash-application lightdash-database lightdash-s3; do
  kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o go-template='{{.metadata.name}}{{" keys: "}}{{range $k,$v := .data}}{{$k}}{{" "}}{{end}}{{"\n"}}'
done
```

Clean up transient credentials only after all three Secrets exist:

```bash
rm -P .context/gke/storage-credential.json 2>/dev/null || true
unset DB_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY LIGHTDASH_SECRET
```

Prepare the strict Helm interface:

```bash
cp docs/gke/values/secrets-external.yaml \
  .context/gke/secrets-values.yaml
```

No Vault token, GCP client key, or application credential is stored in a Pod or
Helm release. Kubernetes Secrets still contain runtime credentials, so restrict
RBAC and enable GKE application-layer secrets encryption if required.

References: [VSO GCP authentication](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/sources/vault/auth/gcp)
and [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso).
