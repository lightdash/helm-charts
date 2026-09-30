# Lightdash on Amazon EKS with AWS CDK: install guide

This guide provisions AWS infrastructure for a self-hosted Lightdash instance and installs
the Lightdash Helm chart onto it, using the AWS CDK project in
[`deploy/aws-cdk`](../deploy/aws-cdk).

Use this path if you have an AWS account and no Kubernetes cluster. If you already have a
cluster, install the chart directly and skip this guide: see the
[chart README](../charts/lightdash/README.md). The chart is identical either way, and this
project does not modify it.

For a full list of context options, resources created, and cost, see the
[project README](../deploy/aws-cdk/README.md).

## Prerequisites

- Node.js 20 or newer. The repository's `flake.nix` provides `nodejs_20`.
- AWS credentials in your environment with permission to create VPC, EKS, RDS, S3, IAM and
  Secrets Manager resources.
- The CDK bootstrapped once per account and region.
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) to inspect the result. Not required
  to deploy.

Expect around 260 USD per month at the defaults in `us-east-1`, of which 73 USD is the EKS
control plane alone. This is not a free-tier deployment.

## 1. Install and review

```bash
cd deploy/aws-cdk
npm install
npx cdk synth
```

`cdk synth` writes CloudFormation to `cdk.out` and creates nothing. Read it before
deploying.

## 2. Bootstrap the account and region

Once per account and region:

```bash
npx cdk bootstrap aws://111122223333/us-east-1
```

## 3. Deploy

With a domain and an ACM certificate, which is what you want for real use:

```bash
npx cdk deploy \
  -c hostname=lightdash.example.com \
  -c certificateArn=arn:aws:acm:us-east-1:111122223333:certificate/abcd1234
```

Without a domain, for evaluation only. The load balancer is reachable from the internet and
serves plain HTTP, so logins and session cookies are not encrypted, and you have to say so
to get it:

```bash
npx cdk deploy -c allowInsecureHttp=true
```

The first deploy takes 25 to 35 minutes. Most of that is the EKS control plane and the RDS
instance.

## 4. Reach the instance

The stack prints the two commands you need. Point `kubectl` at the new cluster:

```bash
aws eks update-kubeconfig --region us-east-1 --name CLUSTER_NAME
```

If that reports `You must be logged in to the server`, your credentials have no entry on the
cluster yet. Creating a cluster does not grant its creator CLI access. Add yourself, using
the role ARN rather than the `assumed-role` ARN that `aws sts get-caller-identity` prints:

```bash
aws eks create-access-entry --cluster-name CLUSTER_NAME --principal-arn YOUR_ROLE_ARN
aws eks associate-access-policy --cluster-name CLUSTER_NAME --principal-arn YOUR_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Passing `-c adminRoleArn=YOUR_ROLE_ARN` at deploy time does the same thing up front.

Then read the load balancer address off the Ingress. It appears two to three minutes after
the release finishes, because the load balancer controller provisions it asynchronously:

```bash
kubectl -n lightdash get ingress lightdash \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open that address and register the first user. If you passed `hostname`, point a DNS record
at the load balancer and use your own address instead.

## 5. Check on it

```bash
kubectl -n lightdash get pods
kubectl -n lightdash logs deploy/lightdash
```

The database password and `LIGHTDASH_SECRET` live in Secrets Manager and are copied into the
cluster by the External Secrets Operator. If the Lightdash pod is stuck in
`CreateContainerConfigError`, the copy has not completed yet:

```bash
kubectl -n lightdash get externalsecrets
kubectl -n external-secrets logs deploy/external-secrets
```

To read the database password:

```bash
aws secretsmanager get-secret-value --secret-id SECRET_ARN \
  --query SecretString --output text
```

The ARN is a stack output.

## 6. Upgrade

Change the chart version and redeploy:

```bash
npx cdk deploy -c chartVersion=2.10.242
```

## 7. Remove everything

```bash
npx cdk destroy
```

By default this deletes the database and the bucket contents along with the cluster. Pass
`-c retainData=true` on the original deploy if you want the database snapshotted and the
bucket kept instead.

If destroy fails while deleting the VPC, the cause is usually a load balancer that outlived
its Ingress. Delete the load balancer and its security group, then run destroy again.
