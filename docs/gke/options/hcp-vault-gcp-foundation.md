# Shared setup: HCP Vault Dedicated with GCP authentication

This setup is shared by the optional VSO and Agent Injector paths. Complete it
once, then return to the secret-delivery option that linked here.

## 1. Create and restrict HCP Vault Dedicated

Use HCP Vault Dedicated Essentials or higher, not a development-tier cluster.
HCP private peering is not directly available to a GCP VPC, so this baseline uses
the public TLS endpoint restricted to the GKE NAT egress IP. A cross-cloud
VPN/transit design is a stricter future option.

In the HCP Portal:

1. Create the HCP Vault Dedicated cluster.
2. Enable its public endpoint.
3. Enable **Allow select IPs only**.
4. Add the GKE `$NAT_IP/32`.
5. Temporarily add your `$ADMIN_PUBLIC_IP/32` while running the administrator
   commands below. Remove it afterward or retain only an approved admin network.
6. Copy the public URL and obtain a short-lived administrator token.

```bash
export VAULT_ADDR="REPLACE_HCP_VAULT_PUBLIC_URL"
export VAULT_NAMESPACE="admin"
export HCP_NAMESPACE="admin"
vault login
vault status
```

`vault login` prompts for the token; do not put it on the command line.

## 2. Create the paths and least-privilege policy

The database and storage guides left credentials in shell variables without
printing them. Verify them and create a fresh application secret:

```bash
test -n "$DB_PASSWORD"
test -n "$S3_ACCESS_KEY"
test -n "$S3_SECRET_KEY"
export LIGHTDASH_SECRET="$(openssl rand -hex 32)"

vault secrets enable -path=kv kv-v2
vault kv put kv/apps/lightdash/application \
  LIGHTDASH_SECRET="$LIGHTDASH_SECRET"
vault kv put kv/apps/lightdash/database \
  PGPASSWORD="$DB_PASSWORD"
vault kv put kv/apps/lightdash/s3 \
  S3_ACCESS_KEY="$S3_ACCESS_KEY" \
  S3_SECRET_KEY="$S3_SECRET_KEY"

vault policy write lightdash-read docs/gke/vault-policy.hcl
```

If `kv/` already exists as KV v2, skip the enable command. Check metadata without
reading secret values:

```bash
vault kv metadata get kv/apps/lightdash/application
vault kv metadata get kv/apps/lightdash/database
vault kv metadata get kv/apps/lightdash/s3
```

## 3. Configure Vault's GCP verifier identity

The HCP-hosted GCP auth plugin needs permission to inspect GCP service-account
metadata and public keys. This baseline imports a narrowly privileged verifier
key into Vault's encrypted storage. That key is never placed in Kubernetes. HCP
Vault Enterprise also supports keyless plugin Workload Identity Federation; use
that more involved setup during infrastructure-as-code hardening.

```bash
export VAULT_VERIFIER_GSA="lightdash-vault-verifier"

gcloud iam roles create VaultGcpAuthVerifier \
  --project="$PROJECT_ID" \
  --file=docs/gke/vault-gcp-verifier-role.yaml

gcloud iam service-accounts create "$VAULT_VERIFIER_GSA" \
  --display-name="Vault GCP auth verifier"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$VAULT_VERIFIER_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/VaultGcpAuthVerifier"

umask 077
gcloud iam service-accounts keys create \
  .context/gke/vault-gcp-verifier-key.json \
  --iam-account="$VAULT_VERIFIER_GSA@$PROJECT_ID.iam.gserviceaccount.com"
export VAULT_VERIFIER_KEY_ID="$(jq -r '.private_key_id' \
  .context/gke/vault-gcp-verifier-key.json)"

vault auth enable gcp
vault write auth/gcp/config \
  credentials=@.context/gke/vault-gcp-verifier-key.json
```

If GCP auth is already configured, have the Vault administrator verify it rather
than overwriting the configuration. After Vault accepts the key, delete only the
local copy. Do not delete the key in GCP until plugin WIF or a replacement
verifier key has been configured and tested.

```bash
chmod 600 .context/gke/vault-gcp-verifier-key.json
rm -P .context/gke/vault-gcp-verifier-key.json
echo "Vault verifier key retained in GCP: $VAULT_VERIFIER_KEY_ID"
```

You should now have the three Vault paths, `lightdash-read` policy, GCP auth
method, `VAULT_ADDR`, `VAULT_NAMESPACE`, and `HCP_NAMESPACE` needed by either
integration.

References: [Vault GCP auth](https://developer.hashicorp.com/vault/docs/auth/gcp),
[HCP Vault public IP allowlists](https://developer.hashicorp.com/hcp/docs/vault/get-started/manage-public-access),
and [Vault plugin WIF](https://developer.hashicorp.com/vault/docs/auth/gcp#plugin-workload-identity-federation-wif).
