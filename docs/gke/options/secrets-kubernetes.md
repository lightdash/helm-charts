# Option: Kubernetes Secrets

[Return to the main guide](../../gke-production-deployment-guide.md#8-deliver-secrets)

This is the recommended starting point. It has fewer components than an external
secret operator or injection webhook, while still keeping credentials out of
Helm values and Helm release history.

Kubernetes Secrets are not a separate secret-management service. Their values
are base64-encoded, not inherently encrypted. Restrict access with Kubernetes
RBAC and enable GKE application-layer secrets encryption when your security
requirements call for it.

## 1. Confirm the credentials are available

The database and storage guides leave their new credentials in the current shell
without printing them. Do not enable shell tracing (`set -x`).

```bash
test -n "$DB_PASSWORD"
test -n "$S3_ACCESS_KEY"
test -n "$S3_SECRET_KEY"
export LIGHTDASH_SECRET="$(openssl rand -hex 32)"
```

If the variables are no longer available, reset the database or storage
credential rather than guessing it.

## 2. Create the three Secrets

The commands pipe generated manifests directly to the API. They do not write a
YAML file containing credentials:

```bash
kubectl -n "$NAMESPACE" create secret generic lightdash-application \
  --from-literal=LIGHTDASH_SECRET="$LIGHTDASH_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic lightdash-database \
  --from-literal=PGPASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic lightdash-s3 \
  --from-literal=S3_ACCESS_KEY="$S3_ACCESS_KEY" \
  --from-literal=S3_SECRET_KEY="$S3_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Anyone who can read Secrets in this namespace can recover their values. Check
your access before proceeding:

```bash
kubectl auth can-i get secrets --namespace="$NAMESPACE"
kubectl auth can-i list secrets --namespace="$NAMESPACE"
```

Production application identities normally should not have either permission.
Only the deployment operators that rotate these values need write access.

## 3. Verify names and keys without decoding values

```bash
kubectl -n "$NAMESPACE" get secret \
  lightdash-application lightdash-database lightdash-s3

for SECRET_NAME in lightdash-application lightdash-database lightdash-s3; do
  kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o go-template='{{.metadata.name}}{{" keys: "}}{{range $k,$v := .data}}{{$k}}{{" "}}{{end}}{{"\n"}}'
done
```

Expected keys:

- `lightdash-application`: `LIGHTDASH_SECRET`
- `lightdash-database`: `PGPASSWORD`
- `lightdash-s3`: `S3_ACCESS_KEY` and `S3_SECRET_KEY`

## 4. Prepare the strict Helm fragment

```bash
cp docs/gke/values/secrets-external.yaml \
  .context/gke/secrets-values.yaml

rm -P .context/gke/storage-credential.json 2>/dev/null || true
unset DB_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY LIGHTDASH_SECRET
```

The fragment enables `secretRefs`, sets `secrets: null`, and contains only Secret
names and key names. The chart should render no Secret objects.

## Rotation

Coordinate database and storage credential rotation with their providers. Then
rerun the applicable `kubectl create secret ... --dry-run ... | kubectl apply`
command and restart the running workloads:

```bash
kubectl -n "$NAMESPACE" rollout restart deployment/lightdash-backend
kubectl -n "$NAMESPACE" rollout restart deployment/lightdash-worker
kubectl -n "$NAMESPACE" rollout status deployment/lightdash-backend --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/lightdash-worker --timeout=10m
```

Changing a Secret does not automatically restart Pods, and a Helm rollback does
not restore an older Secret value. Keep an audited rotation and recovery process.

References: [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/),
[good practices for Kubernetes Secrets](https://kubernetes.io/docs/concepts/security/secrets-good-practices/),
and [GKE application-layer secrets encryption](https://cloud.google.com/kubernetes-engine/docs/how-to/encrypting-secrets).
