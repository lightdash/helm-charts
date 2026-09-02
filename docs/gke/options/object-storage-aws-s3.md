# Option: Amazon S3

[Return to the main guide](../../gke-production-deployment-guide.md#7-configure-s3-compatible-object-storage)

Choose this if your organization already standardizes on AWS S3 or needs an AWS
bucket. From GKE this is a cross-cloud dependency: account for internet egress,
latency, and AWS data-transfer cost. The simple integration below uses a
least-privilege IAM access key because the chart expects S3 credentials.

You need AWS CLI v2 authenticated to the intended account and permission to
create a bucket, IAM user, policy, and access key.

## 1. Create and protect the bucket

```bash
export AWS_REGION="eu-west-1"
export S3_BUCKET="REPLACE_GLOBALLY_UNIQUE_BUCKET"
export S3_USER="lightdash-gke-storage"

aws sts get-caller-identity
aws s3api create-bucket \
  --bucket "$S3_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration "LocationConstraint=$AWS_REGION"

aws s3api put-public-access-block \
  --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-encryption \
  --bucket "$S3_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-versioning \
  --bucket "$S3_BUCKET" \
  --versioning-configuration Status=Enabled
```

For `us-east-1`, omit `--create-bucket-configuration` from `create-bucket`.

Apply lifecycle and browser CORS settings:

```bash
cp docs/gke/aws-s3-cors.json .context/gke/aws-s3-cors.json
cp docs/gke/aws-s3-lifecycle.json .context/gke/aws-s3-lifecycle.json
sed -i '' "s/REPLACE_LIGHTDASH_DOMAIN/$LIGHTDASH_DOMAIN/g" \
  .context/gke/aws-s3-cors.json

aws s3api put-bucket-cors \
  --bucket "$S3_BUCKET" \
  --cors-configuration file://.context/gke/aws-s3-cors.json
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$S3_BUCKET" \
  --lifecycle-configuration file://.context/gke/aws-s3-lifecycle.json
```

## 2. Create bucket-scoped credentials

```bash
cp docs/gke/aws-s3-policy.json .context/gke/aws-s3-policy.json
sed -i '' "s/REPLACE_S3_BUCKET/$S3_BUCKET/g" \
  .context/gke/aws-s3-policy.json

aws iam create-user --user-name "$S3_USER"
aws iam put-user-policy \
  --user-name "$S3_USER" \
  --policy-name LightdashBucketOnly \
  --policy-document file://.context/gke/aws-s3-policy.json

umask 077
aws iam create-access-key --user-name "$S3_USER" \
  > .context/gke/storage-credential.json
export S3_ACCESS_KEY="$(jq -r '.AccessKey.AccessKeyId' \
  .context/gke/storage-credential.json)"
export S3_SECRET_KEY="$(jq -r '.AccessKey.SecretAccessKey' \
  .context/gke/storage-credential.json)"
test "$S3_ACCESS_KEY" != null
test "$S3_SECRET_KEY" != null
```

Do not display these values. Keep this shell open until the secret guide stores
them. The Vault guide deletes the temporary file and unsets the variables.

## 3. Prepare the Helm fragment

```bash
cp docs/gke/values/object-storage-aws-s3.yaml \
  .context/gke/object-storage-values.yaml
sed -i '' "s/REPLACE_AWS_REGION/$AWS_REGION/g" \
  .context/gke/object-storage-values.yaml
sed -i '' "s/REPLACE_S3_BUCKET/$S3_BUCKET/g" \
  .context/gke/object-storage-values.yaml
```

## 4. Verify

```bash
aws s3api get-public-access-block --bucket "$S3_BUCKET"
aws s3api get-bucket-versioning --bucket "$S3_BUCKET"
aws s3api get-bucket-encryption --bucket "$S3_BUCKET"
aws s3api get-bucket-cors --bucket "$S3_BUCKET"
```

For rotation, create a second access key, store it, test Lightdash, and then
deactivate and delete the old key. IAM users permit at most two access keys.

References: [Amazon S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/configuring-block-public-access-bucket.html),
[S3 CORS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enabling-cors-examples.html),
and [IAM access key rotation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html).
