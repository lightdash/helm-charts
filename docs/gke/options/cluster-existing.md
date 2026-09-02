# Option: use an existing GKE cluster

[Return to the main guide](../../gke-production-deployment-guide.md#5-prepare-or-connect-to-gke)

Choose this if a platform team already operates GKE. This guide makes no cluster
changes. Ask the owner to confirm the following before deploying:

- supported GKE version and Regular or Stable release channel;
- Workload Identity Federation for GKE is enabled;
- nodes can reach the chosen PostgreSQL and object storage endpoints;
- if Cloud SQL uses private IP, the cluster VPC has private connectivity to it;
- the GKE Ingress controller is enabled if that exposure option is selected;
- the cluster has enough capacity and topology for two Lightdash replicas;
- NetworkPolicy, Pod Security, quotas, or admission policies that apply;
- a fixed egress IP if HCP Vault or another provider uses an IP allowlist.

Connect without changing the current Git checkout:

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"

gcloud config get-value project
kubectl config current-context
kubectl cluster-info
kubectl auth can-i create deployments --namespace="$NAMESPACE"
kubectl auth can-i create secrets --namespace="$NAMESPACE"
```

If the cluster is zonal, use `--zone=REPLACE_ZONE` instead of `--region`. If the
control plane is private, run these commands from an approved VPN, bastion, or
Cloud Shell environment.

Do not enable or replace cluster features yourself unless the cluster owner has
approved the impact. Record the cluster name, location, project, network, and
egress IP in the deployment change ticket.

Reference: [GKE cluster access](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl).
