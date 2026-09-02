# Option: create a private regional GKE Standard cluster

[Return to the main guide](../../gke-production-deployment-guide.md#5-prepare-or-connect-to-gke)

Choose this for a new production-oriented GCP environment. It creates regional
control-plane availability, private worker nodes, a fixed Cloud NAT egress IP,
VPC-native networking, Dataplane V2, autoscaling, and Workload Identity.

## Prerequisites

You need a GCP billing account, project-owner-like permissions for initial setup,
and your current public IPv4 address. Do not use `0.0.0.0/0` for the Kubernetes
control plane.

```bash
export BILLING_ACCOUNT="REPLACE_BILLING_ACCOUNT_ID"
export ADMIN_PUBLIC_IP="$(curl -4 -fsS https://ifconfig.me)"
export NETWORK="lightdash-vpc"
export SUBNET="lightdash-euw1"
export POD_RANGE="lightdash-pods"
export SERVICE_RANGE="lightdash-services"
export ROUTER="lightdash-router"
export NAT="lightdash-nat"
export NAT_IP_NAME="lightdash-nat-ip"
```

If you do not want an external IP-check service, replace `ADMIN_PUBLIC_IP`
manually with the public IPv4 address shown by your office or VPN administrator.

## Create or select the project

Project IDs are globally unique:

```bash
gcloud auth login
gcloud projects create "$PROJECT_ID" --name="Lightdash production"
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
gcloud config set project "$PROJECT_ID"

gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com
```

If the project already exists, omit `projects create`; verify billing and select
it with `gcloud config set project`.

## Create the network and NAT

The secondary ranges are consumed by Pods and Services. The example CIDRs must
not overlap your company, VPN, or database networks.

```bash
gcloud compute networks create "$NETWORK" --subnet-mode=custom

gcloud compute networks subnets create "$SUBNET" \
  --network="$NETWORK" \
  --region="$REGION" \
  --range="10.20.0.0/20" \
  --secondary-range="$POD_RANGE=10.24.0.0/14,$SERVICE_RANGE=10.28.0.0/20" \
  --enable-private-ip-google-access

gcloud compute addresses create "$NAT_IP_NAME" --region="$REGION"
gcloud compute routers create "$ROUTER" --network="$NETWORK" --region="$REGION"
gcloud compute routers nats create "$NAT" \
  --router="$ROUTER" \
  --region="$REGION" \
  --nat-external-ip-pool="$NAT_IP_NAME" \
  --nat-all-subnet-ip-ranges \
  --enable-logging

export NAT_IP="$(gcloud compute addresses describe "$NAT_IP_NAME" \
  --region="$REGION" --format='value(address)')"
echo "Record this egress IP for external allowlists: $NAT_IP"
```

## Create the cluster

The command creates private nodes but retains a public control-plane endpoint
restricted to your `/32` address. Change machine family and node counts after a
capacity and cost review.

```bash
gcloud container clusters create "$CLUSTER_NAME" \
  --region="$REGION" \
  --release-channel=regular \
  --network="$NETWORK" \
  --subnetwork="$SUBNET" \
  --cluster-secondary-range-name="$POD_RANGE" \
  --services-secondary-range-name="$SERVICE_RANGE" \
  --enable-ip-alias \
  --enable-private-nodes \
  --master-ipv4-cidr="172.16.0.0/28" \
  --enable-master-authorized-networks \
  --master-authorized-networks="$ADMIN_PUBLIC_IP/32" \
  --enable-dataplane-v2 \
  --workload-pool="$PROJECT_ID.svc.id.goog" \
  --machine-type="e2-standard-4" \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=3 \
  --disk-type=pd-balanced \
  --disk-size=100 \
  --no-enable-basic-auth \
  --metadata=disable-legacy-endpoints=true

gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"
```

In the GKE console, enable **Deletion protection** for the new cluster if your
installed `gcloud` version does not expose that setting at creation time.

## Verify

```bash
gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" \
  --format='yaml(location,privateClusterConfig,networkConfig.datapathProvider,workloadIdentityConfig,masterAuthorizedNetworksConfig)'
kubectl get nodes -o wide
```

Node `EXTERNAL-IP` values should be empty. Test the reserved NAT IP from a
temporary Pod and compare it with `$NAT_IP`:

```bash
kubectl run nat-check --rm -i --restart=Never \
  --image=curlimages/curl:8.16.0 -- https://ifconfig.me
```

References: [GKE private nodes](https://cloud.google.com/kubernetes-engine/docs/how-to/legacy/network-isolation),
[Cloud NAT for GKE](https://cloud.google.com/nat/docs/gke-example), and
[Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity).
