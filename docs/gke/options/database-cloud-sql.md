# Option: Cloud SQL for PostgreSQL

[Return to the main guide](../../gke-production-deployment-guide.md#6-configure-postgresql)

Choose this for the recommended GCP production path. It uses PostgreSQL 16,
regional high availability, private IP, backups, point-in-time recovery, deletion
protection, and the Cloud SQL Auth Proxy beside each Lightdash process.

The cluster and Cloud SQL instance must have private network connectivity. These
commands assume the network from the new-cluster guide. For Shared VPC or an
existing cluster, have the network owner complete private service access first.

## 1. Reserve a private services range

```bash
export NETWORK="lightdash-vpc"
export SQL_RANGE="google-managed-services-lightdash-vpc"
export SQL_INSTANCE="lightdash-postgres"

gcloud compute addresses create "$SQL_RANGE" \
  --global \
  --purpose=VPC_PEERING \
  --prefix-length=16 \
  --network="$NETWORK"

gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges="$SQL_RANGE" \
  --network="$NETWORK"
```

If the network already has a suitable allocated range and peering, reuse it
instead of creating another overlapping range.

## 2. Create the database instance

The example tier is a starting point, not a sizing guarantee:

```bash
gcloud sql instances create "$SQL_INSTANCE" \
  --database-version=POSTGRES_16 \
  --region="$REGION" \
  --tier="db-custom-2-7680" \
  --availability-type=REGIONAL \
  --network="$NETWORK" \
  --no-assign-ip \
  --storage-type=SSD \
  --storage-size=100 \
  --storage-auto-increase \
  --backup-start-time="02:00" \
  --enable-point-in-time-recovery \
  --retained-backups-count=14 \
  --retained-transaction-log-days=7 \
  --deletion-protection

gcloud sql databases create lightdash --instance="$SQL_INSTANCE"
```

## 3. Create the database user without printing its password

The password is held only in the current shell until the Vault step stores it.
Shell history records `$DB_PASSWORD`, not its expanded value. Do not enable shell
tracing (`set -x`).

```bash
read -s "DB_PASSWORD?New password for the Lightdash database user: "
echo
export DB_PASSWORD
gcloud sql users create lightdash \
  --instance="$SQL_INSTANCE" \
  --password="$DB_PASSWORD"
```

Keep this terminal open through the Vault guide. After Vault is populated, that
guide unsets the variable. If you lose it first, reset the Cloud SQL password and
use the new value.

## 4. Give Pods a Cloud SQL identity

Create one Google service account (GSA), grant only Cloud SQL Client, then allow
the two Helm-created Kubernetes service accounts (KSAs) to impersonate it:

```bash
export SQL_GSA="lightdash-cloud-sql"

gcloud iam service-accounts create "$SQL_GSA" \
  --display-name="Lightdash Cloud SQL client"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SQL_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

for KSA in lightdash lightdash-migration; do
  gcloud iam service-accounts add-iam-policy-binding \
    "$SQL_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:$PROJECT_ID.svc.id.goog[$NAMESPACE/$KSA]"
done
```

No GCP JSON key is created.

## 5. Prepare the values fragment

```bash
cp docs/gke/values/database-cloud-sql.yaml \
  .context/gke/database-values.yaml
sed -i '' "s/REPLACE_PROJECT_ID/$PROJECT_ID/g" \
  .context/gke/database-values.yaml
sed -i '' "s/REPLACE_CLOUD_SQL_INSTANCE/$SQL_INSTANCE/g" \
  .context/gke/database-values.yaml
```

If you changed the default region, replace `europe-west1` in the local file:

```bash
sed -i '' "s/europe-west1/$REGION/g" .context/gke/database-values.yaml
```

The restartable init container runs the proxy as a sidecar in the backend,
workers, and migration Job. Lightdash connects to `127.0.0.1:5432`; the proxy
connects to the instance over private IP using Workload Identity.

## 6. Verify the controls

```bash
gcloud sql instances describe "$SQL_INSTANCE" \
  --format='yaml(databaseVersion,region,settings.availabilityType,settings.backupConfiguration,settings.deletionProtectionEnabled,ipAddresses)'

gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members:$SQL_GSA@$PROJECT_ID.iam.gserviceaccount.com" \
  --format='table(bindings.role)'
```

There should be a private IP, no public IP, `REGIONAL` availability, enabled
backup/PITR settings, and deletion protection.

Operationally, test a point-in-time restore into a separate instance and monitor
proxy errors. Before deletion, take and verify a final backup, then explicitly
disable deletion protection.

References: [Connect from GKE with the Auth Proxy](https://cloud.google.com/sql/docs/postgres/connect-kubernetes-engine),
[private IP](https://cloud.google.com/sql/docs/postgres/configure-private-ip), and
[backup/PITR](https://cloud.google.com/sql/docs/postgres/backup-recovery/backups).
