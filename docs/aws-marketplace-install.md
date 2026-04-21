# Lightdash on AWS Marketplace — install guide

This guide covers installing Lightdash into your own Kubernetes cluster after subscribing via the [AWS Marketplace listing](https://aws.amazon.com/marketplace/). The product is delivered as a Helm chart hosted in AWS Elastic Container Registry.

For the generic (non-Marketplace) chart, see the [chart README](../charts/lightdash/README.md).

## Prerequisites

- A Kubernetes cluster running 1.27 or later. Amazon EKS and EKS Anywhere are both supported; any CNCF-conformant distribution should work.
- An external PostgreSQL database (version 13 or later). [Amazon RDS](https://aws.amazon.com/rds/postgresql/) is recommended. Create an empty database and a user with `CREATE` privileges — the chart runs schema migrations automatically.
- An ingress controller, or the ability to provision a Kubernetes `LoadBalancer` service.
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) and [`helm`](https://helm.sh/docs/intro/install/) (v3.8+), configured against the target cluster.

## 1. Subscribe via AWS Marketplace

Follow the "Subscribe" / "Continue to configuration" flow on the Marketplace listing. Once the agreement is active, the Helm chart and container images become accessible from the AWS Marketplace ECR registry in your account's region.

## 2. Create a namespace and database secret

```bash
kubectl create namespace lightdash

kubectl -n lightdash create secret generic lightdash-db \
  --from-literal=postgresql-password='<your-db-password>'
```

## 3. Install the chart

Replace `<chartVersion>` with the version shown in the Marketplace portal for the version you subscribed to, and fill in the placeholders for your RDS endpoint and public URL.

```bash
helm install lightdash \
  oci://709825985650.dkr.ecr.us-east-1.amazonaws.com/lightdash/lightdash \
  --version <chartVersion> \
  --namespace lightdash \
  --set externalDatabase.host=<your-rds-endpoint> \
  --set externalDatabase.user=lightdash \
  --set externalDatabase.database=lightdash \
  --set externalDatabase.existingSecret=lightdash-db \
  --set configMap.SITE_URL=https://lightdash.your-domain.com \
  --set secrets.LIGHTDASH_SECRET=<64-character-random-string> \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=lightdash.your-domain.com \
  --set ingress.hosts[0].paths[0].path=/ \
  --set ingress.hosts[0].paths[0].pathType=Prefix
```

Generate the session secret with `openssl rand -hex 32` and keep it safe — it encrypts session cookies and must remain stable across upgrades.

## 4. Access Lightdash

Watch for your ingress / LoadBalancer to be ready:

```bash
kubectl -n lightdash get ingress
```

Once it has an address, open `https://lightdash.your-domain.com` and create the first admin user.

## Upgrading

When a new chart version is available in the Marketplace portal:

```bash
helm upgrade lightdash \
  oci://709825985650.dkr.ecr.us-east-1.amazonaws.com/lightdash/lightdash \
  --version <new-chartVersion> \
  --namespace lightdash \
  --reuse-values
```

The chart runs schema migrations automatically against your external Postgres as a pre-upgrade hook. Downgrades are not supported — take a database snapshot before any upgrade.

## Optional configuration

### TLS to your Postgres

If your Postgres instance requires TLS (RDS with `rds.force_ssl`, for example), provide a CA bundle via a ConfigMap:

```bash
kubectl -n lightdash create configmap rds-ca \
  --from-file=rds-ca-bundle.pem=/path/to/rds-ca-bundle.pem
```

Add `--set ssl.enabled=true --set ssl.configMapName=rds-ca --set ssl.certFileName=rds-ca-bundle.pem` to the `helm install` command.

### Ingress annotations

AWS ALB ingress controllers take annotations per cluster setup. Example for AWS Load Balancer Controller:

```bash
--set ingress.className=alb \
--set "ingress.annotations.alb\.ingress\.kubernetes\.io/scheme=internet-facing" \
--set "ingress.annotations.alb\.ingress\.kubernetes\.io/target-type=ip"
```

### Resource limits

Defaults suit a trial install but should be tuned for production. Override via `--set resources.limits.cpu=...`, `--set resources.limits.memory=...`, etc.

## Uninstalling

```bash
helm uninstall lightdash --namespace lightdash
```

Your external Postgres data is preserved — the uninstall only removes Kubernetes resources.

## Support

- Documentation: https://docs.lightdash.com
- Support: support@lightdash.com
- Enterprise customers get a dedicated Slack channel and onboarding per contract.
