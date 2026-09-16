# Lightdash on Amazon EKS with AWS CDK

Optional deployment path that provisions the AWS infrastructure for a self-hosted
Lightdash instance and then installs the `lightdash` Helm chart from this repository's
published chart repository.

The chart is used unchanged. Nothing here modifies `charts/lightdash`, and `helm install`
remains a first-class way to install Lightdash into a cluster you already have. This
project exists for people who have an AWS account and no cluster.

## What it creates

| Resource | Default | Notes |
|---|---|---|
| VPC | `10.0.0.0/16`, 2 AZs, 1 NAT gateway | Public, private-with-egress, and isolated subnets |
| EKS cluster | Kubernetes 1.31 | Public and private endpoint access |
| Managed node group | 2 x `t3.large`, 30 GB | Private subnets |
| AWS Load Balancer Controller | v2.13.4 | Provisions an ALB from the chart's Ingress |
| RDS PostgreSQL | `t4g.micro`, 20 GB, gp3 | Isolated subnets, not publicly accessible, encrypted |
| S3 bucket | Encrypted, public access blocked | Lightdash results and uploads |
| Secrets Manager | 2 secrets | Database password, `LIGHTDASH_SECRET` |
| External Secrets Operator | v0.10.4 | Copies both secrets into the cluster |
| Lightdash | chart 2.10.241 | Installed from `https://lightdash.github.io/helm-charts` |

Roughly 80 CloudFormation resources in one stack.

### Cost

At the defaults, in `us-east-1`, the recurring charges are approximately:

| Item | Monthly |
|---|---|
| EKS control plane | 73 USD |
| 2 x `t3.large` nodes | 120 USD |
| NAT gateway (plus data processing) | 33 USD |
| RDS `t4g.micro` with 20 GB | 15 USD |
| Application Load Balancer | 17 USD |
| S3, Secrets Manager, logs | 2 USD |

That is on the order of 260 USD per month. It is not a free-tier deployment, and the
largest single line is the EKS control plane, which is charged whether or not anything is
running on it. Run `cdk destroy` when you are finished evaluating.

## Prerequisites

- Node.js 20 or newer. The repository's `flake.nix` provides `nodejs_20`.
- An AWS account, credentials in the environment, and the region you intend to use.
- CDK bootstrapped in that account and region: `npx cdk bootstrap aws://ACCOUNT/REGION`.
- `kubectl` and `helm`, to inspect the result. Neither is needed to deploy.

## Deploy

With a domain and an ACM certificate, which is what anything beyond evaluation wants:

```bash
cd deploy/aws-cdk
npm install
npx cdk synth                       # no AWS writes, and no credentials needed
npx cdk deploy \
  -c hostname=lightdash.example.com \
  -c certificateArn=arn:aws:acm:us-east-1:111122223333:certificate/abc
```

Without a certificate the load balancer is internet-facing and speaks plain HTTP, so
`allowInsecureHttp` has to be set before synth will produce it:

```bash
npx cdk deploy -c allowInsecureHttp=true
```

Anyone who learns the load balancer's DNS name can then reach the login page, and
credentials and session cookies cross the internet in clear text. Use it to see Lightdash
running, not for an instance you intend to keep.

The first deploy takes roughly 25 to 35 minutes, most of it the EKS control plane and the
RDS instance. When it finishes, the stack outputs a `kubectl` command for the cluster and a
command that prints the load balancer hostname:

```bash
aws eks update-kubeconfig --region REGION --name CLUSTER_NAME
kubectl -n lightdash get ingress lightdash \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

The load balancer takes a further two to three minutes to appear after the release
succeeds, because the controller provisions it asynchronously.

### Getting kubectl access

Creating a cluster does not give the identity that created it a way in through the CLI. The
role CDK builds for its own kubectl provider holds the cluster-admin binding, and your own
credentials are not part of it, so `kubectl` answers `You must be logged in to the server`
until an entry exists for them.

Pass the role you deploy with and the stack grants it cluster-admin:

```bash
npx cdk deploy -c adminRoleArn=arn:aws:iam::111122223333:role/YourRole
```

Or add yourself afterwards, which needs only IAM permissions and not cluster access:

```bash
aws eks create-access-entry --cluster-name CLUSTER_NAME --principal-arn YOUR_ROLE_ARN
aws eks associate-access-policy --cluster-name CLUSTER_NAME --principal-arn YOUR_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Use the role ARN, not the `assumed-role` ARN that `aws sts get-caller-identity` prints. The
cluster runs in `API_AND_CONFIG_MAP` mode so that this second path works at all; under
`CONFIG_MAP` alone the only way in is through a ConfigMap that only someone already inside
the cluster can edit.

## Configuration

Every input is CDK context, so pass it with `-c` or commit it to `cdk.context.json`:

```bash
npx cdk deploy \
  -c hostname=lightdash.example.com \
  -c certificateArn=arn:aws:acm:us-east-1:111122223333:certificate/abc \
  -c nodeInstanceType=t3.xlarge
```

| Context key | Default | Purpose |
|---|---|---|
| `region`, `account` | From your credentials | Deployment target |
| `hostname` | none | Public hostname. See "Running without a domain" |
| `certificateArn` | none | ACM certificate for HTTPS. Requires `hostname` |
| `vpcCidr` | `10.0.0.0/16` | VPC range |
| `natGateways` | `1` | Raise to the AZ count for production |
| `maxAzs` | `2` | Availability zones |
| `kubernetesVersion` | `1.31` | See the note below before changing |
| `nodeInstanceType` | `t3.large` | Node size |
| `nodeDiskSizeGb` | `30` | Node disk |
| `nodeMinSize`, `nodeMaxSize`, `nodeDesiredSize` | `2`, `4`, `2` | Node group sizing |
| `dbInstanceType` | `t4g.micro` | Database size |
| `dbAllocatedStorageGb` | `20` | Database storage, autoscaling to `dbMaxAllocatedStorageGb` |
| `dbBackupRetentionDays` | `7` | Automated backup retention, up to the RDS maximum of 35 |
| `dbDeletionProtection` | `false` | Blocks deletion of the database, including by destroy |
| `postgresVersion`, `postgresMajorVersion` | `16`, `16` | Engine version. See the note below |
| `namespace`, `releaseName` | `lightdash` | Kubernetes namespace and Helm release |
| `chartVersion` | `2.10.241` | Chart version to install |
| `chartRepository` | `https://lightdash.github.io/helm-charts` | Chart source |
| `allowInsecureHttp` | `false` | Required to deploy with no certificate. See below |
| `retainData` | `false` | Final database snapshot on destroy, and keep the bucket and secrets |
| `adminRoleArn` | none | IAM role granted cluster-admin. See "Getting kubectl access" |

`postgresVersion` is the major family rather than a pinned minor, which RDS resolves to the
latest minor it supports. A pinned minor stops being deployable once AWS retires it, and
minor upgrades are applied in the maintenance window regardless, so pinning one would only
decide which version the first hour of the instance's life runs. Pass a full version such
as `-c postgresVersion=16.14` if you need a specific minor at creation.

Raising `kubernetesVersion` past 1.31 also requires depending on the matching
`@aws-cdk/lambda-layer-kubectl-vNN` package and importing it in
`lib/constructs/cluster.ts`. CDK pins the kubectl binary by package name, so the version
cannot follow the context value on its own.

## Running without a domain

With no `hostname`, the Ingress matches any host and Lightdash is reachable at the load
balancer's own DNS name, which requires `allowInsecureHttp=true` since there is nothing to
issue a certificate against. `SITE_URL` is left empty in that case, so links Lightdash
generates for itself, including invite and password-reset emails, will not point back at
your instance. `SECURE_COOKIES` is off, because a secure cookie is never sent over HTTP.

To fix that once you know the address, redeploy with it:

```bash
npx cdk deploy -c hostname=$(kubectl -n lightdash get ingress lightdash \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

For anything beyond evaluation, point a domain at the load balancer, issue an ACM
certificate, and pass both `hostname` and `certificateArn`. That also turns on
`SECURE_COOKIES` and an HTTP to HTTPS redirect.

## How credentials reach the pods

The database password and `LIGHTDASH_SECRET` are generated into Secrets Manager and never
placed in Helm values. The External Secrets Operator reads them from inside the cluster
using an IRSA role and materialises two Kubernetes Secrets, which the chart consumes
through its existing `externalDatabase.existingSecret` and `existingSecret` values.

The consequence is that no plaintext credential appears in the CloudFormation template, in
`cdk.context.json`, or in the kubectl provider's event payload. The only copies are in
Secrets Manager and in etcd. Rotating the RDS secret does not require a redeploy, because
the operator refreshes hourly.

S3 access uses IRSA rather than access keys. Lightdash omits explicit credentials when
`S3_ACCESS_KEY` is unset and falls back to the AWS SDK credential chain;
`S3_USE_CREDENTIALS_FROM=token_file` pins it to the projected service account token, so a
broken IRSA setup fails on the first S3 operation rather than quietly falling through to
the node instance profile. Credential resolution is lazy, so the pod still starts and
serves health checks either way.

### Database TLS

RDS PostgreSQL 15 and later refuse unencrypted connections, so `PGSSLMODE=no-verify` is set.
That encrypts the connection without verifying the server certificate, which is a
reasonable position for traffic that never leaves a private subnet.

`no-verify` rather than `require`, which under libpq would mean the same thing. Lightdash
reaches PostgreSQL through node-postgres, where `require` leaves Node's TLS verification on
and the RDS certificate chain is checked against the image's trust store, which contains no
Amazon RDS root. Every start then fails with `self-signed certificate in certificate chain`
before the migrations run.

For certificate verification, put the RDS CA bundle in a ConfigMap and use the chart's
existing SSL support, which sets `PGSSLMODE=verify-full` and points
`NODE_EXTRA_CA_CERTS` at the bundle:

```bash
curl -o global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
kubectl -n lightdash create configmap lightdash-ssl-cert --from-file=global-bundle.pem
```

then set `ssl.enabled=true`, `ssl.certFileName=global-bundle.pem` and
`ssl.configMapName=lightdash-ssl-cert` in the release. The bundle is not vendored here
because it rotates on Amazon's schedule, not this repository's.

## Teardown

```bash
npx cdk destroy
```

With the default `retainData=false` this removes everything, including the database and the
bucket's contents. With `retainData=true` the database is deleted but leaves a final
snapshot behind, and the bucket and secrets are retained, so you are responsible for
deleting all three later.

Deletion protection is off by default and is not tied to `retainData`, because RDS rejects
the delete that either removal policy asks for while protection is on, and destroy then
stops in `DELETE_FAILED` with no snapshot taken. For an instance you want guarded against
an accidental destroy, pass `-c dbDeletionProtection=true` and expect to redeploy with it
off before you can tear the stack down. Set it here rather than in the console, where the
next deploy would quietly revert it.

The load balancer is created by the controller rather than by CloudFormation, and is removed
when the Ingress is deleted with the Helm release. That only works while the controller is
still running, because the finalizer it puts on the Ingress is one only it removes, so the
release is ordered ahead of the controller and the namespace ahead of the node group. If a
destroy is interrupted between those steps, the namespace can be left in `Terminating` with
the load balancer still up. Clear it by removing the finalizers, then delete the load
balancer, its target group and its security groups by hand:

```bash
kubectl -n lightdash patch ingress lightdash --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl -n lightdash get targetgroupbindings -o name | xargs -I{} \
  kubectl -n lightdash patch {} --type=merge -p '{"metadata":{"finalizers":null}}'
```

## Layout

```
bin/lightdash.ts              App entry. Resolves context and instantiates the stack
lib/config.ts                 Every input, its default, and validation
lib/lightdash-stack.ts        Composes the constructs and declares outputs
lib/constructs/network.ts     VPC, subnets, load balancer discovery tags
lib/constructs/cluster.ts     EKS, node group, load balancer controller
lib/constructs/database.ts    RDS PostgreSQL
lib/constructs/storage.ts     S3 bucket
lib/constructs/secret-sync.ts External Secrets Operator and the two ExternalSecrets
lib/constructs/application.ts IRSA service account and the Helm release
```

One stack rather than several: splitting network, data and cluster stacks means exporting a
VPC and a security group across stack boundaries, and CloudFormation then refuses to update
an export while another stack references it. That turns routine changes into manual export
surgery.

## Limitations

- Single AZ database, single NAT gateway, no read replica. This is a small self-hosted
  deployment, not a highly available one.
- No CI in this repository covers this directory. `ct lint` only looks at `charts/**`.
- Upgrades are performed by changing `chartVersion` and redeploying. There is no
  blue/green or canary path.
- The Helm release waits 13 minutes, held under the 15 CDK gives its kubectl provider
  Lambda so that helm reports its own timeout before the Lambda is killed. A cold-start
  migration on a heavily loaded `t4g.micro` can exceed it. The release continues in the
  cluster, and because a timed-out release is left failed rather than pending, redeploying
  upgrades over it and picks up the finished state.
