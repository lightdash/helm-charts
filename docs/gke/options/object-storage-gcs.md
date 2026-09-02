# Option: Google Cloud Storage

[Return to the main guide](../../gke-production-deployment-guide.md#7-configure-s3-compatible-object-storage)

Choose this when Lightdash runs in GCP. Lightdash explicitly supports Cloud
Storage through its S3-compatible XML API. The HMAC key created below is the S3
credential pair; it is separate from GKE Workload Identity.

## 1. Create a private bucket

Bucket names are globally unique. A retention period prevents deletion until the
period expires, including during teardown, so change it only after a governance
review.

```bash
export GCS_BUCKET="REPLACE_GLOBALLY_UNIQUE_BUCKET"
export GCS_SA="lightdash-storage"

gcloud storage buckets create "gs://$GCS_BUCKET" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --uniform-bucket-level-access \
  --public-access-prevention \
  --retention-period=30d

gcloud storage buckets update "gs://$GCS_BUCKET" --versioning
```

Apply a lifecycle and browser CORS policy from local, non-secret copies:

```bash
cp docs/gke/gcs-cors.json .context/gke/gcs-cors.json
cp docs/gke/gcs-lifecycle.json .context/gke/gcs-lifecycle.json
sed -i '' "s/REPLACE_LIGHTDASH_DOMAIN/$LIGHTDASH_DOMAIN/g" \
  .context/gke/gcs-cors.json

gcloud storage buckets update "gs://$GCS_BUCKET" \
  --cors-file=.context/gke/gcs-cors.json \
  --lifecycle-file=.context/gke/gcs-lifecycle.json
```

## 2. Create a bucket-scoped identity and one-time HMAC key

```bash
gcloud iam service-accounts create "$GCS_SA" \
  --display-name="Lightdash object storage"

gcloud storage buckets add-iam-policy-binding "gs://$GCS_BUCKET" \
  --member="serviceAccount:$GCS_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

umask 077
gcloud storage hmac create \
  "$GCS_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  --format=json > .context/gke/storage-credential.json

export S3_ACCESS_KEY="$(jq -r '.metadata.accessId // .accessId' \
  .context/gke/storage-credential.json)"
export S3_SECRET_KEY="$(jq -r '.secret' \
  .context/gke/storage-credential.json)"
test "$S3_ACCESS_KEY" != null
test "$S3_SECRET_KEY" != null
```

The HMAC secret is shown only once. Keep this shell open until the secret guide
stores both variables. Do not display them. The Vault guide deletes the temporary
JSON file and unsets the variables.

## 3. Prepare the Helm fragment

```bash
cp docs/gke/values/object-storage-gcs.yaml \
  .context/gke/object-storage-values.yaml
sed -i '' "s/REPLACE_GCS_BUCKET/$GCS_BUCKET/g" \
  .context/gke/object-storage-values.yaml
```

## 4. Verify non-secret settings

```bash
gcloud storage buckets describe "gs://$GCS_BUCKET" \
  --format='yaml(name,location,iamConfiguration,retentionPolicy,versioning,lifecycle,cors)'
```

Never make the bucket public. For rotation, create and store a second HMAC key,
verify Lightdash after secret reconciliation, and only then deactivate/delete the
old key.

References: [Lightdash external storage](https://docs.lightdash.com/self-host/customize-deployment/configure-lightdash-to-use-external-object-storage),
[Cloud Storage interoperability](https://cloud.google.com/storage/docs/interoperability),
and [HMAC keys](https://cloud.google.com/storage/docs/authentication/hmackeys).
