# Option: MinIO-compatible storage

[Return to the main guide](../../gke-production-deployment-guide.md#7-configure-s3-compatible-object-storage)

Choose this only if your organization already operates a supported,
production-grade MinIO-compatible service and accepts responsibility for its
availability, upgrades, disks, backups, TLS, monitoring, and disaster recovery.

Important in 2026: the former open-source MinIO Operator repository is archived.
MinIO's supported Kubernetes product is AIStor. This guide therefore connects
Lightdash to an existing MinIO/AIStor endpoint; it does not install the archived
operator. A single-process community MinIO deployment is suitable only for a
disposable lab, not this production architecture.

## 1. Collect the endpoint details

You need:

- an HTTPS S3 API endpoint such as `https://minio.example.com`;
- a valid publicly trusted TLS certificate;
- a private `lightdash` bucket with versioning and appropriate retention;
- a dedicated access key limited to that bucket;
- browser CORS allowing only `https://$LIGHTDASH_DOMAIN`;
- an endpoint reachable both from GKE Pods and users' browsers.

The browser requirement matters because Lightdash can use presigned URLs. An
internal-only Kubernetes Service name is not a valid `publicEndpoint` for users.

If your storage operator gives you `mc` credentials for the administrative
endpoint, a typical verification sequence is:

```bash
export MINIO_API_DOMAIN="minio.example.com"
export MINIO_ALIAS="production-minio"

read -s "MINIO_ADMIN_ACCESS_KEY?MinIO administrator access key: "
echo
read -s "MINIO_ADMIN_SECRET_KEY?MinIO administrator secret key: "
echo
mc alias set "$MINIO_ALIAS" "https://$MINIO_API_DOMAIN" \
  "$MINIO_ADMIN_ACCESS_KEY" "$MINIO_ADMIN_SECRET_KEY"
unset MINIO_ADMIN_ACCESS_KEY MINIO_ADMIN_SECRET_KEY
mc ls "$MINIO_ALIAS"
mc version enable "$MINIO_ALIAS/lightdash"
```

Do not place administrator credentials in the Lightdash secret. Create a scoped
application identity using the process and policy tooling required by your MinIO
edition. Export only that identity's values in the current shell:

```bash
read -s "S3_ACCESS_KEY?Lightdash MinIO access key: "
echo
read -s "S3_SECRET_KEY?Lightdash MinIO secret key: "
echo
export S3_ACCESS_KEY S3_SECRET_KEY
```

The exact policy-management commands differ between AIStor and legacy MinIO;
follow your installed version's documentation. Minimum object permissions mirror
the AWS policy in `docs/gke/aws-s3-policy.json`.

## 2. Prepare the Helm fragment

```bash
cp docs/gke/values/object-storage-minio.yaml \
  .context/gke/object-storage-values.yaml
sed -i '' "s/REPLACE_MINIO_API_DOMAIN/$MINIO_API_DOMAIN/g" \
  .context/gke/object-storage-values.yaml
```

If the cluster uses a private internal endpoint, set `s3.endpoint` to it but keep
`s3.publicEndpoint` set to the browser-reachable HTTPS endpoint. Ensure both names
reach the same object namespace and certificate validation succeeds.

## 3. Acceptance checks

Before deploying Lightdash, have the storage owner demonstrate:

- the Lightdash identity can list the bucket and get/put/delete an object;
- it cannot list or modify unrelated buckets;
- CORS preflight succeeds from the exact Lightdash origin;
- node/disk loss and backup restore have been tested;
- monitoring covers capacity, quorum, certificates, and replication.

After deployment, perform a Lightdash upload and download in the browser. A Pod
test alone does not prove `publicEndpoint` or CORS is correct.

References: [Lightdash S3-compatible storage](https://docs.lightdash.com/self-host/customize-deployment/configure-lightdash-to-use-external-object-storage),
[AIStor migration guidance](https://docs.min.io/aistor/administration/upgrade-aistor-server/open-source-minio/kubernetes/),
and the [archived MinIO Operator repository](https://github.com/minio/operator).
